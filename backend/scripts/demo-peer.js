/*
 * Demo peer: a scripted second user for trying the app alone.
 *   node scripts/demo-peer.js <inviteUsernameOrEmail> [apiUrl] [mailpitUrl]
 * Creates (or logs in) the user "dave" (password Demo!pass1), invites the given user,
 * auto-accepts their invitations, shows "typing…" and replies to every message.
 */
import { io } from 'socket.io-client';

const target = process.argv[2];
const API = process.argv[3] || 'http://localhost:3000';
const MAIL = process.argv[4] || process.env.MAILPIT_URL || 'http://localhost:8025';
const EMAIL = 'dave@demo.local';
const USERNAME = 'dave';
const PASSWORD = 'Demo!pass1';

async function api(method, path, { token, body } = {}) {
  const res = await fetch(API + path, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { status: res.status, ...(await res.json().catch(() => ({}))) };
}

async function latestCode(email) {
  for (let i = 0; i < 20; i++) {
    const s = await fetch(`${MAIL}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`).then((r) => r.json());
    if (s.messages?.length) {
      const msg = await fetch(`${MAIL}/api/v1/message/${s.messages[0].ID}`).then((r) => r.json());
      return /\b(\d{6})\b/.exec(msg.Text)[1];
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error('no verification email');
}

async function session() {
  let r = await api('POST', '/api/auth/login', { body: { email: EMAIL, password: PASSWORD } });
  if (r.tokens) return r;
  if (r.error?.code === 'INVALID_CREDENTIALS') {
    await api('POST', '/api/auth/register', { body: { email: EMAIL, username: USERNAME, password: PASSWORD } });
  }
  r = await api('POST', '/api/auth/verify-email', { body: { email: EMAIL, code: await latestCode(EMAIL) } });
  if (!r.tokens) throw new Error(JSON.stringify(r));
  return r;
}

const { user, tokens } = await session();
let token = tokens.accessToken;
let refresh = tokens.refreshToken;
setInterval(async () => {
  const r = await api('POST', '/api/auth/refresh', { body: { refreshToken: refresh } });
  if (r.tokens) ({ accessToken: token, refreshToken: refresh } = r.tokens);
}, 10 * 60 * 1000);
console.log(`[peer] logged in as ${user.username}`);

if (target) {
  const found = await api('GET', `/api/users/search?q=${encodeURIComponent(target)}`, { token });
  const t = found.users?.find((u) => u.username.toLowerCase() === target.toLowerCase()) || found.users?.[0];
  if (t) {
    const r = await api('POST', '/api/invites', { token, body: { userId: t.id } });
    console.log(`[peer] invite to ${t.username}:`, r.status, r.error?.code || 'sent');
  } else console.log(`[peer] user ${target} not found`);
}

const socket = io(API, { auth: (cb) => cb({ token }), transports: ['websocket'] });
socket.on('connect', () => console.log('[peer] socket connected'));
socket.on('invite:new', async (inv) => {
  if (inv.direction !== 'incoming') return;
  await api('POST', `/api/invites/${inv.id}/accept`, { token });
  console.log(`[peer] accepted invite from ${inv.user.username}`);
});
socket.on('message:new', async ({ message }) => {
  if (message.senderId === user.id) return;
  socket.emit('message:delivered', { messageIds: [message.id] });
  console.log(`[peer] got ${message.type}: ${message.text ?? ''}`);
  await new Promise((r) => setTimeout(r, 1500));
  await api('POST', `/api/chats/${message.chatId}/read`, { token });
  socket.emit('typing', { chatId: message.chatId, isTyping: true });
  await new Promise((r) => setTimeout(r, 2500));
  socket.emit('typing', { chatId: message.chatId, isTyping: false });
  const reply = message.type === 'text' ? `You said: "${message.text}" 🙂` : `Nice ${message.type}! 👍`;
  await api('POST', `/api/chats/${message.chatId}/messages`, {
    token,
    body: { clientId: `peer-${Date.now()}`, type: 'text', text: reply },
  });
});
