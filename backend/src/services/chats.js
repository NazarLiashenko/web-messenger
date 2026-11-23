import { query } from '../db.js';
import { decrypt, decryptJson, userKey } from '../crypto.js';
import { notFound } from '../errors.js';
import { mediaUrl } from './media.js';
import { getUsersByIds } from './users.js';
import { emitToUser } from '../realtime.js';

/* Chat membership never changes after a chat is created (1:1 chats), so it is cached. */
const memberCache = new Map();

export async function getChatMemberIds(chatId) {
  if (memberCache.has(chatId)) return memberCache.get(chatId);
  if (!/^[0-9a-f-]{36}$/i.test(String(chatId))) return null;
  const { rows } = await query('SELECT member_enc FROM chat_members WHERE chat_id=$1', [chatId]);
  if (!rows.length) return null;
  const ids = rows.map((r) => decrypt(r.member_enc));
  memberCache.set(chatId, ids);
  return ids;
}

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
     WHERE me.member_key = $1`,
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
  const sender = memberIds.find((id) => userKey(id) === row.sender_key) || null;
  const deleted = !!row.deleted_at;
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
        : { id: row.media_id, url: mediaUrl(row.media_id), mime: row.media_mime, size: row.media_size },
    meta: deleted ? null : decryptJson(row.meta_enc),
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

/** Chat list (or a single chat) from the point of view of `userId`. */
export async function getChatsForUser(userId, { chatId = null } = {}) {
  const me = userKey(userId);
  const { rows } = await query(
    `SELECT c.id, c.created_at, c.last_message_at, mine.archived, mine.muted, peer.member_enc AS peer_enc,
       (SELECT count(*) FROM messages u WHERE u.chat_id = c.id AND u.sender_key <> $1
          AND u.read_at IS NULL AND u.deleted_at IS NULL)::int AS unread,
       lm.id AS lm_id
     FROM chat_members mine
     JOIN chats c ON c.id = mine.chat_id
     JOIN chat_members peer ON peer.chat_id = c.id AND peer.member_key <> mine.member_key
     LEFT JOIN LATERAL (SELECT id FROM messages m WHERE m.chat_id = c.id ORDER BY m.created_at DESC LIMIT 1) lm ON true
     WHERE mine.member_key = $1 AND ($2::uuid IS NULL OR c.id = $2)
     ORDER BY COALESCE(c.last_message_at, c.created_at) DESC`,
    [me, chatId],
  );
  const peerIds = rows.map((r) => decrypt(r.peer_enc));
  const lastIds = rows.map((r) => r.lm_id).filter(Boolean);
  const [users, lastMessages] = await Promise.all([
    getUsersByIds(peerIds),
    lastIds.length
      ? query(`${MESSAGE_SELECT} WHERE m.id = ANY($1::uuid[])`, [lastIds]).then(
          (r) => new Map(r.rows.map((m) => [m.id, m])),
        )
      : new Map(),
  ]);
  return rows.map((r, i) => {
    const peerId = peerIds[i];
    const lm = r.lm_id ? lastMessages.get(r.lm_id) : null;
    return {
      id: r.id,
      peer: users.get(peerId) || { id: peerId, username: 'Deleted user', about: '', avatarUrl: null },
      archived: r.archived,
      muted: r.muted,
      unreadCount: r.unread,
      lastMessage: lm ? serializeMessage(lm, [userId, peerId]) : null,
      lastActivityAt: r.last_message_at || r.created_at,
      createdAt: r.created_at,
    };
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
  const { rows } = await query(
    `UPDATE messages SET read_at = now(), delivered_at = COALESCE(delivered_at, now())
     WHERE chat_id = $2 AND sender_key <> $1 AND read_at IS NULL AND deleted_at IS NULL
     RETURNING id, chat_id, read_at`,
    [userKey(userId), chatId],
  );
  if (rows.length) await emitStatus(rows, 'read', 'read_at');
  return rows.length;
}
