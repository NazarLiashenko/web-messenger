import crypto from 'node:crypto';
import { query } from '../db.js';
import { decrypt, decryptJson, encryptJson, userKey } from '../crypto.js';
import { notFound } from '../errors.js';
import { mediaUrl } from './media.js';
import { getUsersByIds } from './users.js';
import { emitToUser } from '../realtime.js';

/*
 * Active member ids per chat are cached (hot path: every message / typing event).
 * 1:1 chats never change; group membership changes call invalidateMembers().
 */
const memberCache = new Map();
/* member_key (blind index) -> user id, also for people who left a group, so their old messages keep a sender. */
const idByKey = new Map();

export async function getChatMemberIds(chatId) {
  if (memberCache.has(chatId)) return memberCache.get(chatId);
  if (!/^[0-9a-f-]{36}$/i.test(String(chatId))) return null;
  const { rows } = await query('SELECT member_enc, member_key, left_at FROM chat_members WHERE chat_id=$1', [chatId]);
  if (!rows.length) return null;
  const ids = [];
  for (const r of rows) {
    const id = decrypt(r.member_enc);
    idByKey.set(r.member_key, id);
    if (!r.left_at) ids.push(id);
  }
  memberCache.set(chatId, ids);
  return ids;
}

export const invalidateMembers = (chatId) => memberCache.delete(chatId);

export async function assertMember(chatId, userId) {
  const ids = await getChatMemberIds(chatId);
  if (!ids || !ids.includes(userId)) throw notFound('Chat');
  return ids;
}

/** Ids of every user that shares a chat with the given user (their contacts). */
export async function getContactIds(userId) {
  const { rows } = await query(
    `SELECT p.member_enc FROM chat_members me
     JOIN chat_members p ON p.chat_id = me.chat_id AND p.member_key <> me.member_key
     WHERE me.member_key = $1 AND me.left_at IS NULL AND p.left_at IS NULL`,
    [userKey(userId)],
  );
  return rows.map((r) => decrypt(r.member_enc));
}

export const MESSAGE_SELECT = `SELECT m.*, md.mime AS media_mime, md.size AS media_size
  FROM messages m LEFT JOIN media md ON md.id = m.media_id`;

export function messageStatus(row) {
  if (row.read_at) return 'read';
  if (row.delivered_at) return 'delivered';
  return 'sent';
}

export function serializeMessage(row, memberIds) {
  const sender = memberIds.find((id) => userKey(id) === row.sender_key) || idByKey.get(row.sender_key) || null;
  const deleted = !!row.deleted_at;
  const meta = deleted ? null : decryptJson(row.meta_enc);
  return {
    id: row.id,
    chatId: row.chat_id,
    clientId: row.client_id,
    senderId: sender,
    type: row.type,
    text: deleted ? null : decrypt(row.body_enc),
    media:
      deleted || !row.media_id
        ? null
        : {
            id: row.media_id,
            url: mediaUrl(row.media_id),
            mime: row.media_mime,
            size: row.media_size,
            thumbnailUrl: meta?.thumbnailMediaId ? mediaUrl(meta.thumbnailMediaId) : null,
          },
    meta,
    createdAt: row.created_at,
    editedAt: row.edited_at,
    deletedAt: row.deleted_at,
    deliveredAt: row.delivered_at,
    readAt: row.read_at,
    status: messageStatus(row),
  };
}

export async function getMessage(messageId) {
  const { rows } = await query(`${MESSAGE_SELECT} WHERE m.id = $1`, [messageId]);
  return rows[0] || null;
}

/**
 * Chat list (or a single chat) from the point of view of `userId`.
 * Direct chats carry `peer`; groups carry `title`, `members` (with roles) and `myRole`.
 */
export async function getChatsForUser(userId, { chatId = null } = {}) {
  const me = userKey(userId);
  const { rows } = await query(
    `SELECT c.id, c.kind, c.title_enc, c.created_at, c.last_message_at, mine.archived, mine.muted, mine.role,
       (SELECT count(*) FROM messages u WHERE u.chat_id = c.id AND u.sender_key <> $1
          AND u.deleted_at IS NULL AND u.type <> 'system'
          AND CASE WHEN c.kind = 'group' THEN u.created_at > COALESCE(mine.last_read_at, mine.joined_at)
                   ELSE u.read_at IS NULL END)::int AS unread,
       lm.id AS lm_id
     FROM chat_members mine
     JOIN chats c ON c.id = mine.chat_id
     LEFT JOIN LATERAL (SELECT id FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) lm ON true
     WHERE mine.member_key = $1 AND mine.left_at IS NULL AND ($2::uuid IS NULL OR c.id = $2)
     ORDER BY COALESCE(c.last_message_at, c.created_at) DESC`,
    [me, chatId],
  );
  if (!rows.length) return [];
  const chatIds = rows.map((r) => r.id);
  const lastIds = rows.map((r) => r.lm_id).filter(Boolean);
  const [memberRows, lastMessages] = await Promise.all([
    query(
      `SELECT chat_id, member_enc, member_key, role FROM chat_members
       WHERE chat_id = ANY($1::uuid[]) AND left_at IS NULL ORDER BY joined_at`,
      [chatIds],
    ).then((r) => r.rows),
    lastIds.length
      ? query(`${MESSAGE_SELECT} WHERE m.id = ANY($1::uuid[])`, [lastIds]).then(
          (r) => new Map(r.rows.map((m) => [m.id, m])),
        )
      : new Map(),
  ]);
  const membersByChat = new Map();
  for (const m of memberRows) {
    const id = decrypt(m.member_enc);
    idByKey.set(m.member_key, id);
    if (!membersByChat.has(m.chat_id)) membersByChat.set(m.chat_id, []);
    membersByChat.get(m.chat_id).push({ id, role: m.role });
  }
  const users = await getUsersByIds(memberRows.map((m) => decrypt(m.member_enc)));
  const userOf = (id) => users.get(id) || { id, username: 'Deleted user', about: '', avatarUrl: null };

  return rows.map((r) => {
    const members = membersByChat.get(r.id) || [];
    const memberIds = members.map((m) => m.id);
    const lm = r.lm_id ? lastMessages.get(r.lm_id) : null;
    const base = {
      id: r.id,
      kind: r.kind,
      archived: r.archived,
      muted: r.muted,
      unreadCount: r.unread,
      lastMessage: lm ? serializeMessage(lm, memberIds) : null,
      lastActivityAt: r.last_message_at || r.created_at,
      createdAt: r.created_at,
    };
    if (r.kind === 'group') {
      return {
        ...base,
        title: decrypt(r.title_enc),
        myRole: r.role,
        memberCount: members.length,
        members: members.map((m) => ({ ...userOf(m.id), role: m.role })),
        peer: null,
      };
    }
    const peerId = memberIds.find((id) => id !== userId) || userId;
    return { ...base, peer: userOf(peerId) };
  });
}

export async function getChatForUser(chatId, userId) {
  const [chat] = await getChatsForUser(userId, { chatId });
  return chat || null;
}

function emitStatus(rows, status, field) {
  const byChat = new Map();
  for (const r of rows) {
    if (!byChat.has(r.chat_id)) byChat.set(r.chat_id, []);
    byChat.get(r.chat_id).push(r);
  }
  return Promise.all(
    [...byChat.entries()].map(async ([chatId, list]) => {
      const ids = await getChatMemberIds(chatId);
      const payload = { chatId, messageIds: list.map((r) => r.id), status, at: list[0][field] };
      ids.forEach((id) => emitToUser(id, 'message:status', payload));
    }),
  );
}

/** Marks messages addressed to `userId` as delivered (all pending ones, or only `messageIds`). */
export async function markDelivered(userId, messageIds = null) {
  const { rows } = await query(
    `UPDATE messages m SET delivered_at = now()
     FROM chat_members cm
     WHERE cm.chat_id = m.chat_id AND cm.member_key = $1 AND m.sender_key <> $1
       AND m.delivered_at IS NULL AND m.deleted_at IS NULL
       AND ($2::uuid[] IS NULL OR m.id = ANY($2::uuid[]))
     RETURNING m.id, m.chat_id, m.delivered_at`,
    [userKey(userId), messageIds],
  );
  if (rows.length) await emitStatus(rows, 'delivered', 'delivered_at');
  return rows.length;
}

export async function markRead(userId, chatId) {
  await query('UPDATE chat_members SET last_read_at = now() WHERE chat_id = $1 AND member_key = $2', [
    chatId,
    userKey(userId),
  ]);
  const { rows } = await query(
    `UPDATE messages SET read_at = now(), delivered_at = COALESCE(delivered_at, now())
     WHERE chat_id = $2 AND sender_key <> $1 AND read_at IS NULL AND deleted_at IS NULL
     RETURNING id, chat_id, read_at`,
    [userKey(userId), chatId],
  );
  if (rows.length) await emitStatus(rows, 'read', 'read_at');
  return rows.length;
}

/** Sends `chat:updated` with each member's own view of the chat (archived / muted are per member). */
export async function emitChatUpdated(chatId) {
  const ids = await getChatMemberIds(chatId);
  await Promise.all(
    (ids || []).map(async (uid) => {
      const chat = await getChatForUser(chatId, uid);
      if (chat) emitToUser(uid, 'chat:updated', chat);
    }),
  );
}

/**
 * Group event shown in the chat history ("Anna added Bob", "Bob left"…).
 * Stored as an encrypted message of type `system`; `meta.event` says what happened.
 */
export async function postSystemMessage(chatId, actorId, event, data = {}) {
  const id = crypto.randomUUID();
  await query(
    `INSERT INTO messages (id, chat_id, client_id, sender_key, type, meta_enc) VALUES ($1,$2,$3,$4,'system',$5)`,
    [id, chatId, `system-${id}`, userKey(actorId), encryptJson({ event, actorId, ...data })],
  );
  await query('UPDATE chats SET last_message_at = now() WHERE id = $1', [chatId]);
  const memberIds = await getChatMemberIds(chatId);
  const message = serializeMessage(await getMessage(id), memberIds);
  memberIds.forEach((uid) => emitToUser(uid, 'message:new', { message }));
  return message;
}
