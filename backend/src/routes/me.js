import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { query, tx } from '../db.js';
import { emailIndex, encrypt, hashPassword, sha256, usernameIndex, verifyPassword } from '../crypto.js';
import { ApiError, assertStrongPassword, emailSchema, parse, usernameSchema } from '../errors.js';
import { requireAuth, revokeAllSessions } from '../auth.js';
import { singleUpload } from '../upload.js';
import { deleteMedia, resolveMime, storeMedia } from '../services/media.js';
import { getUserRow, replaceSearchTokens, serializeUser } from '../services/users.js';
import { consumeCode, issueCode } from '../services/codes.js';
import { getContactIds } from '../services/chats.js';
import { emitToUser } from '../realtime.js';

const router = Router();
router.use(requireAuth);

async function currentUser(req) {
  const row = await getUserRow(req.userId);
  if (!row) throw new ApiError(401, 'UNAUTHORIZED', 'Account no longer exists');
  return row;
}

/** Tell the user's other devices and their contacts that the public profile changed. */
async function broadcastProfile(row) {
  const pub = serializeUser(row);
  const contacts = await getContactIds(row.id);
  contacts.forEach((id) => emitToUser(id, 'user:updated', pub));
  emitToUser(row.id, 'me:updated', serializeUser(row, { self: true }));
}

router.get('/', async (req, res) => {
  res.json({ user: serializeUser(await currentUser(req), { self: true }) });
});

router.patch('/', async (req, res) => {
  const body = parse(
    z.object({ username: usernameSchema.optional(), about: z.string().max(500, 'must be at most 500 characters').optional() }),
    req.body,
  );
  await tx(async (c) => {
    if (body.username !== undefined) {
      const { rows } = await c.query('SELECT 1 FROM users WHERE username_hash=$1 AND id<>$2', [usernameIndex(body.username), req.userId]);
      if (rows.length) throw new ApiError(409, 'USERNAME_TAKEN', 'This username is already taken', { field: 'username' });
      await c.query('UPDATE users SET username_hash=$2, username_enc=$3, updated_at=now() WHERE id=$1', [
        req.userId,
        usernameIndex(body.username),
        encrypt(body.username),
      ]);
      await replaceSearchTokens(c, req.userId, body.username);
    }
    if (body.about !== undefined) {
      const about = body.about.trim();
      await c.query('UPDATE users SET about_enc=$2, updated_at=now() WHERE id=$1', [req.userId, about ? encrypt(about) : null]);
    }
  }).catch((e) => {
    if (e.code === '23505') throw new ApiError(409, 'USERNAME_TAKEN', 'This username is already taken', { field: 'username' });
    throw e;
  });
  const row = await currentUser(req);
  await broadcastProfile(row);
  res.json({ user: serializeUser(row, { self: true }) });
});

router.put('/avatar', singleUpload(config.limits.avatarBytes, 'Profile picture'), async (req, res) => {
  const mime = resolveMime(req.file, 'avatar');
  const old = await currentUser(req);
  const media = await storeMedia({ ownerId: req.userId, kind: 'avatar', mime, buffer: req.file.buffer });
  await query('UPDATE users SET avatar_media_id=$2, updated_at=now() WHERE id=$1', [req.userId, media.id]);
  await deleteMedia(old.avatar_media_id);
  const row = await currentUser(req);
  await broadcastProfile(row);
  res.json({ user: serializeUser(row, { self: true }) });
});

router.delete('/avatar', async (req, res) => {
  const old = await currentUser(req);
  await query('UPDATE users SET avatar_media_id=NULL, updated_at=now() WHERE id=$1', [req.userId]);
  await deleteMedia(old.avatar_media_id);
  const row = await currentUser(req);
  await broadcastProfile(row);
  res.json({ user: serializeUser(row, { self: true }) });
});

router.post('/password', async (req, res) => {
  const body = parse(z.object({ currentPassword: z.string().min(1), newPassword: z.string().min(1) }), req.body);
  const row = await currentUser(req);
  if (!(await verifyPassword(body.currentPassword, row.password_hash))) {
    throw new ApiError(400, 'WRONG_PASSWORD', 'Current password is incorrect', { field: 'currentPassword' });
  }
  assertStrongPassword(body.newPassword, 'newPassword');
  await query('UPDATE users SET password_hash=$2, updated_at=now() WHERE id=$1', [req.userId, await hashPassword(body.newPassword)]);
  await revokeAllSessions(req.userId, req.sessionId); // log out other devices
  res.json({ ok: true });
});

/** Email change: step 1 — send a code to the new address. */
router.post('/email', async (req, res) => {
  const body = parse(z.object({ newEmail: emailSchema, password: z.string().min(1) }), req.body);
  const row = await currentUser(req);
  if (!(await verifyPassword(body.password, row.password_hash))) {
    throw new ApiError(400, 'WRONG_PASSWORD', 'Password is incorrect', { field: 'password' });
  }
  const { rows } = await query('SELECT 1 FROM users WHERE email_hash=$1', [emailIndex(body.newEmail)]);
  if (rows.length) throw new ApiError(409, 'EMAIL_TAKEN', 'This email is already registered', { field: 'newEmail' });
  await query('UPDATE users SET pending_email_hash=$2, pending_email_enc=$3 WHERE id=$1', [
    req.userId,
    emailIndex(body.newEmail),
    encrypt(body.newEmail.toLowerCase()),
  ]);
  const emailSent = await issueCode(req.userId, body.newEmail, 'change_email');
  res.json({ ok: true, emailSent });
});

/** Email change: step 2 — confirm with the code. */
router.post('/email/confirm', async (req, res) => {
  const body = parse(z.object({ code: z.string().trim().min(4) }), req.body);
  const row = await currentUser(req);
  if (!row.pending_email_hash) throw new ApiError(400, 'NO_PENDING_EMAIL', 'There is no pending email change');
  await consumeCode(req.userId, 'change_email', body.code);
  try {
    await query(
      `UPDATE users SET email_hash=pending_email_hash, email_enc=pending_email_enc,
         pending_email_hash=NULL, pending_email_enc=NULL, email_verified=true, updated_at=now() WHERE id=$1`,
      [req.userId],
    );
  } catch (e) {
    if (e.code === '23505') throw new ApiError(409, 'EMAIL_TAKEN', 'This email is already registered', { field: 'newEmail' });
    throw e;
  }
  const updated = await currentUser(req);
  emitToUser(req.userId, 'me:updated', serializeUser(updated, { self: true }));
  res.json({ user: serializeUser(updated, { self: true }) });
});

/** Register an FCM token for push notifications. */
router.post('/push-token', async (req, res) => {
  const body = parse(z.object({ token: z.string().min(10).max(4096), platform: z.string().max(20).optional() }), req.body);
  await query(
    `INSERT INTO push_tokens (token_hash, user_id, token_enc, platform) VALUES ($1,$2,$3,$4)
     ON CONFLICT (token_hash) DO UPDATE SET user_id=EXCLUDED.user_id, platform=EXCLUDED.platform`,
    [sha256(body.token), req.userId, encrypt(body.token), body.platform || null],
  );
  res.json({ ok: true });
});

export default router;
