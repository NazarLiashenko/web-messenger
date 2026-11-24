import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { query, tx } from '../db.js';
import { decrypt, encrypt, userKey } from '../crypto.js';
import { ApiError, badRequest, forbidden, notFound, parse, uuidSchema } from '../errors.js';
import { requireAuth } from '../auth.js';
import {
  assertMember,
  emitChatUpdated,
  getChatForUser,
  getChatMemberIds,
  invalidateMembers,
  postSystemMessage,
} from '../services/chats.js';
import { createGroupInvite, serializeInvites } from './invites.js';
import { emitToUser } from '../realtime.js';

/*
 * Group chats.
 *   POST   /api/groups                      create {title, memberIds?} -> invitations are sent to memberIds
 *   GET    /api/groups/:id                  group + pending invitations
 *   PATCH  /api/groups/:id                  rename {title} (owner)
 *   POST   /api/groups/:id/invites          invite {userId} (any member)
 *   POST   /api/groups/:id/leave            leave (ownership passes to the longest-standing member)
 *   DELETE /api/groups/:id/members/:userId  remove a member (owner)
 * Accepting / declining / cancelling goes through /api/invites like 1:1 invitations.
 */
const router = Router();
router.use(requireAuth);

const titleSchema = z.string().trim().min(1, 'Group name is required').max(64, 'Group name is too long (max 64)');

async function usernameOf(userId) {
  const { rows } = await query('SELECT username_enc FROM users WHERE id=$1', [userId]);
  return rows.length ? decrypt(rows[0].username_enc) : 'Deleted user';
}

/** Loads a group the user belongs to; 404 for anything else (including 1:1 chats). */
async function loadGroup(chatId, userId) {
  if (!/^[0-9a-f-]{36}$/i.test(String(chatId))) throw notFound('Group');
  await assertMember(chatId, userId);
  const { rows } = await query(
    `SELECT c.id, c.kind, c.title_enc, cm.role FROM chats c
     JOIN chat_members cm ON cm.chat_id = c.id AND cm.member_key = $2 AND cm.left_at IS NULL
     WHERE c.id = $1`,
    [chatId, userKey(userId)],
  );
  if (!rows.length || rows[0].kind !== 'group') throw notFound('Group');
  return { id: rows[0].id, title: decrypt(rows[0].title_enc), role: rows[0].role };
}

async function pendingInvites(chatId, userId) {
  const { rows } = await query(
    `SELECT * FROM invitations WHERE chat_id=$1 AND status='pending' ORDER BY created_at`,
    [chatId],
  );
  return serializeInvites(rows, userId);
}

router.post('/', async (req, res) => {
  const body = parse(
    z.object({ title: titleSchema, memberIds: z.array(uuidSchema).max(50, 'Too many people at once').optional() }),
    req.body,
  );
  const id = crypto.randomUUID();
  await tx(async (c) => {
    await c.query(`INSERT INTO chats (id, kind, title_enc) VALUES ($1, 'group', $2)`, [id, encrypt(body.title)]);
    await c.query(
      `INSERT INTO chat_members (chat_id, member_key, member_enc, role, last_read_at) VALUES ($1,$2,$3,'owner', now())`,
      [id, userKey(req.userId), encrypt(req.userId)],
    );
  });
  const me = await usernameOf(req.userId);
  await postSystemMessage(id, req.userId, 'created', { actorName: me, title: body.title });

  const invites = [];
  const failed = [];
  for (const uid of [...new Set(body.memberIds || [])].filter((u) => u !== req.userId)) {
    try {
      invites.push(await createGroupInvite({ chatId: id, title: body.title, fromId: req.userId, toId: uid }));
    } catch (e) {
      failed.push({ userId: uid, code: e.code || 'ERROR', message: e.message });
    }
  }
  const chat = await getChatForUser(id, req.userId);
  emitToUser(req.userId, 'chat:new', chat);
  res.status(201).json({ chat, invites, failed });
});

router.get('/:id', async (req, res) => {
  await loadGroup(req.params.id, req.userId);
  res.json({ chat: await getChatForUser(req.params.id, req.userId), invites: await pendingInvites(req.params.id, req.userId) });
});

router.patch('/:id', async (req, res) => {
  const { title } = parse(z.object({ title: titleSchema }), req.body);
  const group = await loadGroup(req.params.id, req.userId);
  if (group.role !== 'owner') throw forbidden('Only the group owner can rename the group');
  if (title !== group.title) {
    await query('UPDATE chats SET title_enc=$2 WHERE id=$1', [group.id, encrypt(title)]);
    await postSystemMessage(group.id, req.userId, 'renamed', { actorName: await usernameOf(req.userId), title });
    await emitChatUpdated(group.id);
  }
  res.json({ chat: await getChatForUser(group.id, req.userId) });
});

router.post('/:id/invites', async (req, res) => {
  const { userId } = parse(z.object({ userId: uuidSchema }), req.body);
  const group = await loadGroup(req.params.id, req.userId);
  const invite = await createGroupInvite({ chatId: group.id, title: group.title, fromId: req.userId, toId: userId });
  res.status(201).json({ invite });
});

/** Marks a member as gone, hands over ownership if needed and tells everyone. */
async function removeMember(group, userId, actorId) {
  const key = userKey(userId);
  await tx(async (c) => {
    await c.query(`UPDATE chat_members SET left_at = now(), role = 'member' WHERE chat_id=$1 AND member_key=$2`, [
      group.id,
      key,
    ]);
    const owner = await c.query(
      `SELECT 1 FROM chat_members WHERE chat_id=$1 AND role='owner' AND left_at IS NULL`,
      [group.id],
    );
    if (!owner.rows.length) {
      await c.query(
        `UPDATE chat_members SET role='owner' WHERE chat_id=$1 AND member_key = (
           SELECT member_key FROM chat_members WHERE chat_id=$1 AND left_at IS NULL ORDER BY joined_at LIMIT 1)`,
        [group.id],
      );
    }
  });
  invalidateMembers(group.id);
  const remaining = await getChatMemberIds(group.id);
  if (!remaining.length) {
    // Nobody left: pending invitations into an empty group make no sense.
    await query(`UPDATE invitations SET status='cancelled', responded_at=now() WHERE chat_id=$1 AND status='pending'`, [
      group.id,
    ]);
  }
  emitToUser(userId, 'chat:removed', { chatId: group.id });
  const targetName = await usernameOf(userId);
  if (remaining.length) {
    const event = actorId === userId ? 'left' : 'removed';
    await postSystemMessage(group.id, actorId, event, {
      actorName: await usernameOf(actorId),
      targetId: userId,
      targetName,
    });
    await emitChatUpdated(group.id);
  }
}

router.post('/:id/leave', async (req, res) => {
  const group = await loadGroup(req.params.id, req.userId);
  await removeMember(group, req.userId, req.userId);
  res.json({ ok: true });
});

router.delete('/:id/members/:userId', async (req, res) => {
  const group = await loadGroup(req.params.id, req.userId);
  if (group.role !== 'owner') throw forbidden('Only the group owner can remove members');
  const target = req.params.userId;
  if (target === req.userId) throw badRequest('VALIDATION_ERROR', 'Use "Leave group" to leave');
  const ids = await getChatMemberIds(group.id);
  if (!ids.includes(target)) throw new ApiError(404, 'NOT_FOUND', 'This person is not in the group');
  await removeMember(group, target, req.userId);
  res.json({ chat: await getChatForUser(group.id, req.userId) });
});

export default router;
