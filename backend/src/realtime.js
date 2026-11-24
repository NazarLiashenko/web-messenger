import { Server } from 'socket.io';
import { isSessionActive, verifyAccessToken } from './auth.js';
import { query } from './db.js';
import { getChatMemberIds, getContactIds, markDelivered } from './services/chats.js';

/*
 * Real-time channel (Socket.IO).
 * Server -> client events:
 *   message:new, message:updated, message:status, typing, presence,
 *   chat:new, chat:updated, chat:removed (left / removed from a group),
 *   invite:new, invite:updated, user:updated
 * Client -> server events:
 *   typing {chatId, isTyping}, message:delivered {messageIds}
 */
let io = null;
const online = new Map(); // userId -> Set<socketId>

export const isOnline = (userId) => online.has(userId);

export function emitToUser(userId, event, payload) {
  io?.to(`user:${userId}`).emit(event, payload);
}

async function broadcastPresence(userId, isOn) {
  const contacts = await getContactIds(userId);
  const payload = { userId, online: isOn, lastSeenAt: isOn ? null : new Date().toISOString() };
  contacts.forEach((id) => emitToUser(id, 'presence', payload));
}

export function initRealtime(httpServer) {
  io = new Server(httpServer, { cors: { origin: '*' }, pingInterval: 20000, pingTimeout: 20000 });

  io.use(async (socket, next) => {
    try {
      const token = socket.handshake.auth?.token || socket.handshake.query?.token;
      const payload = verifyAccessToken(token);
      if (!(await isSessionActive(payload.sid))) throw new Error('session revoked');
      socket.data.userId = payload.sub;
      next();
    } catch {
      const err = new Error('UNAUTHORIZED');
      err.data = { code: 'UNAUTHORIZED' };
      next(err);
    }
  });

  io.on('connection', (socket) => {
    const userId = socket.data.userId;
    socket.join(`user:${userId}`);
    const first = !online.has(userId);
    if (first) online.set(userId, new Set());
    online.get(userId).add(socket.id);
    if (first) broadcastPresence(userId, true).catch(() => {});

    socket.on('typing', async (data) => {
      try {
        const ids = await getChatMemberIds(data?.chatId);
        if (!ids?.includes(userId)) return;
        ids
          .filter((id) => id !== userId)
          .forEach((id) => emitToUser(id, 'typing', { chatId: data.chatId, userId, isTyping: !!data.isTyping }));
      } catch {
        /* ignore malformed typing events */
      }
    });

    socket.on('message:delivered', async (data, ack) => {
      try {
        const ids = Array.isArray(data?.messageIds) ? data.messageIds.filter((x) => /^[0-9a-f-]{36}$/i.test(x)) : [];
        if (ids.length) await markDelivered(userId, ids);
        ack?.({ ok: true });
      } catch (e) {
        ack?.({ ok: false, error: e.message });
      }
    });

    socket.on('disconnect', async () => {
      const set = online.get(userId);
      set?.delete(socket.id);
      if (set && set.size === 0) {
        online.delete(userId);
        await query('UPDATE users SET last_seen_at = now() WHERE id = $1', [userId]).catch(() => {});
        broadcastPresence(userId, false).catch(() => {});
      }
    });
  });

  return io;
}
