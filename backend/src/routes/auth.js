import crypto from 'node:crypto';
import { Router } from 'express';
import { rateLimit } from 'express-rate-limit';
import { z } from 'zod';
import { query, tx } from '../db.js';
import { emailIndex, encrypt, hashPassword, sha256, usernameIndex, verifyPassword } from '../crypto.js';
import { ApiError, assertStrongPassword, emailSchema, parse, usernameSchema } from '../errors.js';
import { createSession, revokeAllSessions, revokeSessionByRefresh, rotateSession } from '../auth.js';
import { consumeCode, issueCode } from '../services/codes.js';
import { replaceSearchTokens, serializeUser } from '../services/users.js';

const router = Router();

const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: 100,
  standardHeaders: 'draft-8',
  legacyHeaders: false,
  validate: false,
  handler: (_req, res) =>
    res.status(429).json({ error: { code: 'RATE_LIMITED', message: 'Too many attempts. Try again in a few minutes.' } }),
});
router.use(authLimiter);

async function findUserByEmail(email) {
  const { rows } = await query('SELECT * FROM users WHERE email_hash=$1', [emailIndex(email)]);
  return rows[0] || null;
}

const takenError = (field) =>
  new ApiError(409, field === 'email' ? 'EMAIL_TAKEN' : 'USERNAME_TAKEN',
    field === 'email' ? 'This email is already registered' : 'This username is already taken', { field });

/** Live availability check used by the registration form. */
router.get('/availability', async (req, res) => {
  const result = {};
  if (req.query.email) {
    const { rows } = await query('SELECT 1 FROM users WHERE email_hash=$1', [emailIndex(String(req.query.email))]);
    result.emailAvailable = rows.length === 0;
  }
  if (req.query.username) {
    const { rows } = await query('SELECT 1 FROM users WHERE username_hash=$1', [usernameIndex(String(req.query.username))]);
    result.usernameAvailable = rows.length === 0;
  }
  res.json(result);
});

router.post('/register', async (req, res) => {
  const body = parse(
    z.object({ email: emailSchema, username: usernameSchema, password: z.string().min(1, 'is required') }),
    req.body,
  );
  assertStrongPassword(body.password);

  const [byEmail, byUsername] = await Promise.all([
    query('SELECT 1 FROM users WHERE email_hash=$1', [emailIndex(body.email)]),
    query('SELECT 1 FROM users WHERE username_hash=$1', [usernameIndex(body.username)]),
  ]);
  if (byEmail.rows.length) throw takenError('email');
  if (byUsername.rows.length) throw takenError('username');

  const id = crypto.randomUUID();
  const passwordHash = await hashPassword(body.password);
  try {
    await tx(async (c) => {
      await c.query(
        `INSERT INTO users (id, email_hash, email_enc, username_hash, username_enc, password_hash)
         VALUES ($1,$2,$3,$4,$5,$6)`,
        [id, emailIndex(body.email), encrypt(body.email.toLowerCase()), usernameIndex(body.username), encrypt(body.username), passwordHash],
      );
      await replaceSearchTokens(c, id, body.username);
    });
  } catch (e) {
    if (e.code === '23505') throw takenError(e.constraint?.includes('email') ? 'email' : 'username');
    throw e;
  }
  const emailSent = await issueCode(id, body.email, 'verify_email', { enforceCooldown: false });
  res.status(201).json({ email: body.email.toLowerCase(), verificationRequired: true, emailSent });
});

router.post('/verify-email', async (req, res) => {
  const body = parse(z.object({ email: emailSchema, code: z.string().trim().min(4), device: z.string().max(200).optional() }), req.body);
  const user = await findUserByEmail(body.email);
  if (!user) throw new ApiError(404, 'NOT_FOUND', 'Account not found');
  if (!user.email_verified) {
    await consumeCode(user.id, 'verify_email', body.code);
    await query('UPDATE users SET email_verified=true, updated_at=now() WHERE id=$1', [user.id]);
    user.email_verified = true;
  }
  const tokens = await createSession(user.id, body.device);
  res.json({ user: serializeUser(user, { self: true }), tokens });
});

router.post('/resend-verification', async (req, res) => {
  const body = parse(z.object({ email: emailSchema }), req.body);
  const user = await findUserByEmail(body.email);
  if (user && !user.email_verified) {
    const emailSent = await issueCode(user.id, body.email, 'verify_email');
    return res.json({ ok: true, emailSent });
  }
  res.json({ ok: true });
});

router.post('/login', async (req, res) => {
  const body = parse(z.object({ email: emailSchema, password: z.string().min(1, 'is required'), device: z.string().max(200).optional() }), req.body);
  const user = await findUserByEmail(body.email);
  if (!user || !(await verifyPassword(body.password, user.password_hash))) {
    throw new ApiError(401, 'INVALID_CREDENTIALS', 'Incorrect email or password');
  }
  if (!user.email_verified) {
    // Send a fresh code (ignore cooldown errors) and tell the client to show the verification screen.
    await issueCode(user.id, body.email, 'verify_email').catch(() => {});
    throw new ApiError(403, 'EMAIL_NOT_VERIFIED', 'Please confirm your email first. We sent you a code.', { email: body.email.toLowerCase() });
  }
  const tokens = await createSession(user.id, body.device);
  res.json({ user: serializeUser(user, { self: true }), tokens });
});

router.post('/refresh', async (req, res) => {
  const body = parse(z.object({ refreshToken: z.string().min(10) }), req.body);
  const { tokens } = await rotateSession(body.refreshToken);
  res.json({ tokens });
});

router.post('/logout', async (req, res) => {
  const body = parse(z.object({ refreshToken: z.string().optional(), pushToken: z.string().optional() }), req.body);
  if (body.refreshToken) await revokeSessionByRefresh(body.refreshToken);
  if (body.pushToken) await query('DELETE FROM push_tokens WHERE token_hash=$1', [sha256(body.pushToken)]);
  res.json({ ok: true });
});

router.post('/forgot-password', async (req, res) => {
  const body = parse(z.object({ email: emailSchema }), req.body);
  const user = await findUserByEmail(body.email);
  // Same response whether or not the account exists (no account enumeration).
  if (user) await issueCode(user.id, body.email, 'reset_password');
  res.json({ ok: true });
});

router.post('/reset-password', async (req, res) => {
  const body = parse(z.object({ email: emailSchema, code: z.string().trim().min(4), password: z.string().min(1) }), req.body);
  assertStrongPassword(body.password);
  const user = await findUserByEmail(body.email);
  if (!user) throw new ApiError(400, 'INVALID_CODE', 'The code is incorrect', { field: 'code' });
  await consumeCode(user.id, 'reset_password', body.code);
  // A successful reset also proves ownership of the email address.
  await query('UPDATE users SET password_hash=$2, email_verified=true, updated_at=now() WHERE id=$1', [
    user.id,
    await hashPassword(body.password),
  ]);
  await revokeAllSessions(user.id);
  res.json({ ok: true });
});

export default router;
