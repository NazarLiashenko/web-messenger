import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { query, tx } from '../db.js';
import { blindIndex, decrypt, encrypt, pairKey, userKey } from '../crypto.js';
import { ApiError, badRequest, notFound, parse, uuidSchema } from '../errors.js';
import { requireAuth } from '../auth.js';
import { getUsersByIds } from '../services/users.js';
import {
  emitChatUpdated,
  getChatForUser,
  getChatMemberIds,
  invalidateMembers,
  postSystemMessage,
} from '../services/chats.js';
import { emitToUser, isOnline } from '../realtime.js';
import { pushToUser } from '../push.js';

const router = Router();
router.use(requireAuth);

export async function serializeInvites(rows, me) {
  const ids = rows.flatMap((r) => [decrypt(r.from_enc), decrypt(r.to_enc)]);
  const groupIds = [...new Set(rows.map((r) => r.chat_id).filter(Boolean))];
  const [users, groups] = await Promise.all([
    getUsersByIds(ids),
    groupIds.length
      ? query(
          `SELECT c.id, c.title_enc,
             (SELECT count(*) FROM chat_members m WHERE m.chat_id = c.id AND m.left_at IS NULL)::int AS member_count
           FROM chats c WHERE c.id = ANY($1::uuid[])`,
          [groupIds],
        ).then((r) => new Map(r.rows.map((g) => [g.id, { id: g.id, title: decrypt(g.title_enc), memberCount: g.member_count }])))
      : new Map(),
  ]);
  const myKey = userKey(me);
  return rows.map((r) => {
    const fromId = decrypt(r.from_enc);
    const toId = decrypt(r.to_enc);
    const outgoing = r.from_key === myKey;
    return {
      id: r.id,
      kind: r.chat_id ? 'group' : 'direct',
      group: r.chat_id ? groups.get(r.chat_id) || null : null,
      direction: outgoing ? 'outgoing' : 'incoming',
      status: r.status,
      from: users.get(fromId) || { id: fromId, username: 'Deleted user' },
      to: users.get(toId) || { id: toId, username: 'Deleted user' },
      user: users.get(outgoing ? toId : fromId) || null, // the other person
      createdAt: r.created_at,
      respondedAt: r.responded_at,
    };
  });
}

async function serializeInvite(row, me) {
  return (await serializeInvites([row], me))[0];
}

/** Creates the 1:1 chat for two users (idempotent) and returns its id. */
async function createChat(client, a, b) {
  const pk = pairKey(a, b);
  const existing = await client.query('SELECT id FROM chats WHERE pair_key=$1', [pk]);
  if (existing.rows.length) return existing.rows[0].id;
  const id = crypto.randomUUID();
  await client.query('INSERT INTO chats (id, pair_key) VALUES ($1,$2)', [id, pk]);
  for (const uid of [a, b]) {
    await client.query('INSERT INTO chat_members (chat_id, member_key, member_enc) VALUES ($1,$2,$3)', [id, userKey(uid), encrypt(uid)]);
  }
  return id;
}

/** Invitation into a group: pair_key is a blind index of (group, invitee), so one pending invite per person. */
export async function createGroupInvite({ chatId, title, fromId, toId }) {
  if (toId === fromId) throw badRequest('INVALID_INVITE', 'You cannot invite yourself');
  const target = await query('SELECT id, email_verified FROM users WHERE id=$1', [toId]);
  if (!target.rows.length || !target.rows[0].email_verified) throw notFound('User');
  const members = await getChatMemberIds(chatId);
  if (members?.includes(toId)) throw new ApiError(409, 'ALREADY_MEMBER', 'This person is already in the group');

  const id = crypto.randomUUID();
  try {
    await query(
      `INSERT INTO invitations (id, from_key, to_key, from_enc, to_enc, pair_key, chat_id) VALUES ($1,$2,$3,$4,$5,$6,$7)`,
      [id, userKey(fromId), userKey(toId), encrypt(fromId), encrypt(toId), blindIndex(`${chatId}:${toId}`, 'ginvite'), chatId],
    );
  } catch (e) {
    if (e.code === '23505') throw new ApiError(409, 'INVITE_ALREADY_SENT', 'This person has already been invited');
    throw e;
  }
  const row = (await query('SELECT * FROM invitations WHERE id=$1', [id])).rows[0];
  const forSender = await serializeInvite(row, fromId);
  emitToUser(fromId, 'invite:new', forSender);
  emitToUser(toId, 'invite:new', await serializeInvite(row, toId));
  if (!isOnline(toId)) {
    pushToUser(toId, {
      title: 'New group invitation',
      body: `${forSender.from.username} invited you to "${title}"`,
      data: { type: 'invite', inviteId: id },
    });
  }
  return forSender;
}

async function acceptGroupInvite(row) {
  const fromId = decrypt(row.from_enc);
  const toId = decrypt(row.to_enc);
  const chatId = row.chat_id;
  await tx(async (c) => {
    const upd = await c.query(
      `UPDATE invitations SET status='accepted', responded_at=now() WHERE id=$1 AND status='pending' RETURNING id`,
      [row.id],
    );
    if (!upd.rows.length) throw new ApiError(409, 'INVITE_NOT_PENDING', 'This invitation is no longer pending');
    const active = await c.query('SELECT 1 FROM chat_members WHERE chat_id=$1 AND left_at IS NULL LIMIT 1', [chatId]);
    if (!active.rows.length) throw new ApiError(410, 'GROUP_GONE', 'This group no longer exists');
    // Re-joining after leaving reuses the old row (keeps the sender of old messages).
    await c.query(
      `INSERT INTO chat_members (chat_id, member_key, member_enc, role, last_read_at) VALUES ($1,$2,$3,'member', now())
       ON CONFLICT (chat_id, member_key) DO UPDATE
         SET left_at = NULL, role = 'member', joined_at = now(), last_read_at = now(), archived = false`,
      [chatId, userKey(toId), encrypt(toId)],
    );
  });
  invalidateMembers(chatId);
  const updated = (await query('SELECT * FROM invitations WHERE id=$1', [row.id])).rows[0];
  for (const uid of [fromId, toId]) emitToUser(uid, 'invite:updated', await serializeInvite(updated, uid));
  const names = await getUsersByIds([toId, fromId]);
  await postSystemMessage(chatId, toId, 'joined', {
    actorName: names.get(toId)?.username,
    invitedById: fromId,
    invitedByName: names.get(fromId)?.username,
  });
  emitToUser(toId, 'chat:new', await getChatForUser(chatId, toId));
  await emitChatUpdated(chatId);
  return chatId;
}

async function acceptInvite(row) {
  if (row.chat_id) return acceptGroupInvite(row);
  const fromId = decrypt(row.from_enc);
  const toId = decrypt(row.to_enc);
  const chatId = await tx(async (c) => {
    const upd = await c.query(
      `UPDATE invitations SET status='accepted', responded_at=now() WHERE id=$1 AND status='pending' RETURNING id`,
      [row.id],
    );
    if (!upd.rows.length) throw new ApiError(409, 'INVITE_NOT_PENDING', 'This invitation is no longer pending');
    return createChat(c, fromId, toId);
  });
  const updated = (await query('SELECT * FROM invitations WHERE id=$1', [row.id])).rows[0];
  for (const uid of [fromId, toId]) {
    emitToUser(uid, 'invite:updated', await serializeInvite(updated, uid));
    emitToUser(uid, 'chat:new', await getChatForUser(chatId, uid));
  }
  return chatId;
}

router.get('/', async (req, res) => {
  const me = userKey(req.userId);
  const { rows } = await query(
    `SELECT * FROM invitations WHERE status='pending' AND (to_key=$1 OR from_key=$1) ORDER BY created_at DESC`,
    [me],
  );
  const all = await serializeInvites(rows, req.userId);
  res.json({ incoming: all.filter((i) => i.direction === 'incoming'), outgoing: all.filter((i) => i.direction === 'outgoing') });
});

router.post('/', async (req, res) => {
  const { userId } = parse(z.object({ userId: uuidSchema }), req.body);
  if (userId === req.userId) throw badRequest('INVALID_INVITE', 'You cannot invite yourself');
  const target = await query('SELECT id, email_verified FROM users WHERE id=$1', [userId]);
  if (!target.rows.length || !target.rows[0].email_verified) throw notFound('User');

  const pk = pairKey(req.userId, userId);
  const chat = await query('SELECT id FROM chats WHERE pair_key=$1', [pk]);
  if (chat.rows.length) {
    throw new ApiError(409, 'ALREADY_IN_CHATS', 'This user is already in your chat list', { chatId: chat.rows[0].id });
  }
  const pending = await query(`SELECT * FROM invitations WHERE pair_key=$1 AND status='pending'`, [pk]);
  if (pending.rows.length) {
    const inv = pending.rows[0];
    if (inv.from_key === userKey(req.userId)) {
      throw new ApiError(409, 'INVITE_ALREADY_SENT', 'You have already invited this user', { inviteId: inv.id });
    }
    // They already invited us: inviting back simply accepts their invitation.
    const chatId = await acceptInvite(inv);
    return res.json({ accepted: true, chat: await getChatForUser(chatId, req.userId) });
  }

  const id = crypto.randomUUID();
  try {
    await query(
      `INSERT INTO invitations (id, from_key, to_key, from_enc, to_enc, pair_key) VALUES ($1,$2,$3,$4,$5,$6)`,
      [id, userKey(req.userId), userKey(userId), encrypt(req.userId), encrypt(userId), pk],
    );
  } catch (e) {
    if (e.code === '23505') throw new ApiError(409, 'INVITE_ALREADY_SENT', 'An invitation is already pending');
    throw e;
  }
  const row = (await query('SELECT * FROM invitations WHERE id=$1', [id])).rows[0];
  const forSender = await serializeInvite(row, req.userId);
  emitToUser(req.userId, 'invite:new', forSender);
  emitToUser(userId, 'invite:new', await serializeInvite(row, userId));
  if (!isOnline(userId)) {
    pushToUser(userId, {
      title: 'New chat invitation',
      body: `${forSender.from.username} wants to chat with you`,
      data: { type: 'invite', inviteId: id },
    });
  }
  res.status(201).json({ invite: forSender });
});

async function loadInvite(req) {
  if (!/^[0-9a-f-]{36}$/i.test(req.params.id)) throw notFound('Invitation');
  const { rows } = await query('SELECT * FROM invitations WHERE id=$1', [req.params.id]);
  const row = rows[0];
  const me = userKey(req.userId);
  if (!row || (row.to_key !== me && row.from_key !== me)) throw notFound('Invitation');
  if (row.status !== 'pending') throw new ApiError(409, 'INVITE_NOT_PENDING', `This invitation was already ${row.status}`);
  return row;
}

router.post('/:id/accept', async (req, res) => {
  const row = await loadInvite(req);
  if (row.to_key !== userKey(req.userId)) throw notFound('Invitation');
  const chatId = await acceptInvite(row);
  res.json({ chat: await getChatForUser(chatId, req.userId) });
});

async function closeInvite(req, res, status, mustBe) {
  const row = await loadInvite(req);
  if (row[mustBe] !== userKey(req.userId)) throw notFound('Invitation');
  await query('UPDATE invitations SET status=$2, responded_at=now() WHERE id=$1', [row.id, status]);
  const updated = (await query('SELECT * FROM invitations WHERE id=$1', [row.id])).rows[0];
  for (const uid of [decrypt(row.from_enc), decrypt(row.to_enc)]) {
    emitToUser(uid, 'invite:updated', await serializeInvite(updated, uid));
  }
  res.json({ invite: await serializeInvite(updated, req.userId) });
}

router.post('/:id/decline', (req, res) => closeInvite(req, res, 'declined', 'to_key'));
router.delete('/:id', (req, res) => closeInvite(req, res, 'cancelled', 'from_key'));

export default router;
