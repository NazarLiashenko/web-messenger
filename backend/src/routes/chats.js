import crypto from 'node:crypto';
import { Router } from 'express';
import { z } from 'zod';
import { query } from '../db.js';
import { decrypt, decryptJson, encrypt, encryptJson, userKey } from '../crypto.js';
import { ApiError, badRequest, forbidden, notFound, parse } from '../errors.js';
import { requireAuth } from '../auth.js';
import {
  MESSAGE_SELECT,
  assertMember,
  getChatForUser,
  getChatsForUser,
  getMessage,
  markDelivered,
  markRead,
  serializeMessage,
} from '../services/chats.js';
import { deleteMedia } from '../services/media.js';
import { emitToUser, isOnline } from '../realtime.js';
import { pushToUser } from '../push.js';

export const chatsRouter = Router();
export const messagesRouter = Router();
chatsRouter.use(requireAuth);
messagesRouter.use(requireAuth);

const PREVIEW = { image: '📷 Photo', video: '🎬 Video', audio: '🎤 Voice message' };
export const messagePreview = (m) => (m.type === 'text' ? m.text : m.text ? `${PREVIEW[m.type]}: ${m.text}` : PREVIEW[m.type]);

chatsRouter.get('/', async (req, res) => {
  // Fetching the chat list means the client has received everything sent while it was offline.
  await markDelivered(req.userId);
  let chats = await getChatsForUser(req.userId);
  if (req.query.archived === 'true') chats = chats.filter((c) => c.archived);
  else if (req.query.archived === 'false') chats = chats.filter((c) => !c.archived);
  res.json({ chats });
});

chatsRouter.get('/:id', async (req, res) => {
  await assertMember(req.params.id, req.userId);
  res.json({ chat: await getChatForUser(req.params.id, req.userId) });
});

chatsRouter.patch('/:id', async (req, res) => {
  const body = parse(z.object({ archived: z.boolean().optional(), muted: z.boolean().optional() }), req.body);
  await assertMember(req.params.id, req.userId);
  await query(
    `UPDATE chat_members SET archived = COALESCE($3, archived), muted = COALESCE($4, muted)
     WHERE chat_id = $1 AND member_key = $2`,
    [req.params.id, userKey(req.userId), body.archived ?? null, body.muted ?? null],
  );
  const chat = await getChatForUser(req.params.id, req.userId);
  emitToUser(req.userId, 'chat:updated', chat); // sync the user's other devices
  res.json({ chat });
});

chatsRouter.get('/:id/messages', async (req, res) => {
  const memberIds = await assertMember(req.params.id, req.userId);
  const limit = Math.min(Math.max(parseInt(req.query.limit, 10) || 50, 1), 100);
  const before = req.query.before ? new Date(String(req.query.before)) : null;
  if (before && isNaN(before)) throw badRequest('VALIDATION_ERROR', 'before: invalid date');
  const { rows } = await query(
    `${MESSAGE_SELECT} WHERE m.chat_id = $1 AND ($2::timestamptz IS NULL OR m.created_at < $2)
     ORDER BY m.created_at DESC LIMIT $3`,
    [req.params.id, before, limit + 1],
  );
  const hasMore = rows.length > limit;
  const messages = rows.slice(0, limit).reverse().map((r) => serializeMessage(r, memberIds));
  res.json({ messages, hasMore });
});

const sendSchema = z.object({
  clientId: z.string().min(1).max(64),
  type: z.enum(['text', 'image', 'video', 'audio']),
  text: z.string().max(4000, 'message is too long (max 4000 characters)').optional().nullable(),
  mediaId: z.string().optional().nullable(),
  meta: z
    .object({
      durationMs: z.number().int().nonnegative().optional(),
      width: z.number().int().positive().optional(),
      height: z.number().int().positive().optional(),
      fileName: z.string().max(255).optional(),
      waveform: z.array(z.number()).max(100).optional(),
      thumbnailMediaId: z.string().regex(/^[0-9a-f-]{36}$/i).optional(), // video preview (image media)
    })
    .optional()
    .nullable(),
});

chatsRouter.post('/:id/messages', async (req, res) => {
  const chatId = req.params.id;
  const memberIds = await assertMember(chatId, req.userId);
  const body = parse(sendSchema, req.body);
  const text = body.text?.trim() || null;
  const senderKey = userKey(req.userId);

  if (body.type === 'text' && !text) throw badRequest('VALIDATION_ERROR', 'Message cannot be empty', { field: 'text' });
  if (body.type !== 'text') {
    if (!body.mediaId) throw badRequest('VALIDATION_ERROR', 'mediaId is required', { field: 'mediaId' });
    const { rows } = await query('SELECT owner_id, kind FROM media WHERE id = $1', [body.mediaId]);
    if (!rows.length || rows[0].owner_id !== req.userId) throw notFound('Media');
    if (rows[0].kind !== body.type) throw badRequest('VALIDATION_ERROR', `Media is not ${body.type}`, { field: 'mediaId' });
  }
  const thumbId = body.meta?.thumbnailMediaId;
  if (thumbId) {
    const { rows } = await query('SELECT owner_id, kind FROM media WHERE id = $1', [thumbId]);
    if (!rows.length || rows[0].owner_id !== req.userId || rows[0].kind !== 'image') throw notFound('Thumbnail');
  }

  const id = crypto.randomUUID();
  const inserted = await query(
    `INSERT INTO messages (id, chat_id, client_id, sender_key, type, body_enc, media_id, meta_enc)
     VALUES ($1,$2,$3,$4,$5,$6,$7,$8)
     ON CONFLICT (chat_id, sender_key, client_id) DO NOTHING RETURNING id`,
    [id, chatId, body.clientId, senderKey, body.type, encrypt(text), body.type === 'text' ? null : body.mediaId, encryptJson(body.meta || null)],
  );

  if (!inserted.rows.length) {
    // Retry of a message that already reached the server: return the stored copy (idempotent send).
    const { rows } = await query(`${MESSAGE_SELECT} WHERE m.chat_id=$1 AND m.sender_key=$2 AND m.client_id=$3`, [
      chatId,
      senderKey,
      body.clientId,
    ]);
    return res.json({ message: serializeMessage(rows[0], memberIds) });
  }

  await query('UPDATE chats SET last_message_at = now() WHERE id = $1', [chatId]);
  const message = serializeMessage(await getMessage(id), memberIds);
  memberIds.forEach((uid) => emitToUser(uid, 'message:new', { message }));
  res.status(201).json({ message });

  // Push notification for recipients that are offline (online clients notify locally via the socket).
  const recipients = memberIds.filter((uid) => uid !== req.userId && !isOnline(uid));
  if (recipients.length) {
    const sender = await query('SELECT username_enc FROM users WHERE id=$1', [req.userId]);
    for (const uid of recipients) {
      const m = await query('SELECT muted FROM chat_members WHERE chat_id=$1 AND member_key=$2', [chatId, userKey(uid)]);
      if (m.rows[0]?.muted) continue;
      pushToUser(uid, {
        title: decrypt(sender.rows[0].username_enc),
        body: messagePreview(message),
        data: { type: 'message', chatId },
      });
    }
  }
});

chatsRouter.post('/:id/read', async (req, res) => {
  await assertMember(req.params.id, req.userId);
  const count = await markRead(req.userId, req.params.id);
  res.json({ ok: true, count });
});

/* ---- editing / deleting individual messages ---- */

async function loadOwnMessage(req) {
  if (!/^[0-9a-f-]{36}$/i.test(req.params.id)) throw notFound('Message');
  const row = await getMessage(req.params.id);
  if (!row) throw notFound('Message');
  const memberIds = await assertMember(row.chat_id, req.userId);
  if (row.sender_key !== userKey(req.userId)) throw forbidden('You can only change your own messages');
  if (row.deleted_at) throw new ApiError(410, 'MESSAGE_DELETED', 'This message was deleted');
  return { row, memberIds };
}

messagesRouter.patch('/:id', async (req, res) => {
  const body = parse(z.object({ text: z.string().max(4000) }), req.body);
  const { row, memberIds } = await loadOwnMessage(req);
  const text = body.text.trim();
  if (row.type === 'text' && !text) throw badRequest('VALIDATION_ERROR', 'Message cannot be empty', { field: 'text' });
  await query('UPDATE messages SET body_enc=$2, edited_at=now() WHERE id=$1', [row.id, encrypt(text || null)]);
  const message = serializeMessage(await getMessage(row.id), memberIds);
  memberIds.forEach((uid) => emitToUser(uid, 'message:updated', { message }));
  res.json({ message });
});

messagesRouter.delete('/:id', async (req, res) => {
  const { row, memberIds } = await loadOwnMessage(req);
  await query('UPDATE messages SET deleted_at=now(), body_enc=NULL, meta_enc=NULL, media_id=NULL WHERE id=$1', [row.id]);
  await deleteMedia(row.media_id);
  const oldMeta = row.meta_enc ? decryptJson(row.meta_enc) : null;
  if (oldMeta?.thumbnailMediaId) await deleteMedia(oldMeta.thumbnailMediaId);
  const message = serializeMessage(await getMessage(row.id), memberIds);
  memberIds.forEach((uid) => emitToUser(uid, 'message:updated', { message }));
  res.json({ message });
});
