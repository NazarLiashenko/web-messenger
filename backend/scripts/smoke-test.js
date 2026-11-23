/*
 * End-to-end smoke test against a running backend (docker compose up).
 *   node scripts/smoke-test.js [apiUrl] [mailpitUrl]
 * Requires the dev dependency socket.io-client (npm install).
 */
import assert from 'node:assert/strict';
import { io } from 'socket.io-client';

const API = process.argv[2] || 'http://localhost:3000';
const MAIL = process.argv[3] || process.env.MAILPIT_URL || 'http://localhost:8025';
const run = Date.now().toString(36);
const PASSWORD = 'Str0ng!Pass';

async function api(method, path, { token, body, form } = {}) {
  const headers = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body) headers['Content-Type'] = 'application/json';
  const res = await fetch(API + path, { method, headers, body: form || (body ? JSON.stringify(body) : undefined) });
  const json = await res.json().catch(() => ({}));
  return { status: res.status, ...json };
}

async function mailCode(email) {
  for (let i = 0; i < 20; i++) {
    const s = await fetch(`${MAIL}/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`).then((r) => r.json());
    if (s.messages?.length) {
      const msg = await fetch(`${MAIL}/api/v1/message/${s.messages[0].ID}`).then((r) => r.json());
      return /\b(\d{6})\b/.exec(msg.Text)[1];
    }
    await new Promise((r) => setTimeout(r, 300));
  }
  throw new Error(`no email for ${email}`);
}

const waitFor = (socket, event, pred = () => true, ms = 5000) =>
  new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error(`timeout waiting for ${event}`)), ms);
    const h = (d) => {
      if (pred(d)) {
        clearTimeout(t);
        socket.off(event, h);
        resolve(d);
      }
    };
    socket.on(event, h);
  });

async function createUser(name) {
  const email = `${name}.${run}@example.com`;
  const username = `${name}_${run}`;
  let r = await api('POST', '/api/auth/register', { body: { email, username, password: PASSWORD } });
  assert.equal(r.status, 201, JSON.stringify(r));
  r = await api('POST', '/api/auth/login', { body: { email, password: PASSWORD } });
  assert.equal(r.error?.code, 'EMAIL_NOT_VERIFIED');
  const code = await mailCode(email);
  r = await api('POST', '/api/auth/verify-email', { body: { email, code } });
  assert.equal(r.status, 200, JSON.stringify(r));
  assert.equal(r.user.about, '');
  assert.equal(r.user.avatarUrl, null);
  return { email, username, id: r.user.id, token: r.tokens.accessToken, refresh: r.tokens.refreshToken };
}

const step = (name) => console.log(`✔ ${name}`);

const weak = await api('POST', '/api/auth/register', { body: { email: `w${run}@example.com`, username: `w_${run}`, password: 'weakpass' } });
assert.equal(weak.error.code, 'WEAK_PASSWORD');
step('weak password rejected: ' + weak.error.message);

const alice = await createUser('alice');
const bob = await createUser('bob');
step('register + email verification');

let r = await api('POST', '/api/auth/register', { body: { email: alice.email, username: `x_${run}`, password: PASSWORD } });
assert.equal(r.error.code, 'EMAIL_TAKEN');
r = await api('POST', '/api/auth/register', { body: { email: `x${run}@example.com`, username: alice.username.toUpperCase(), password: PASSWORD } });
assert.equal(r.error.code, 'USERNAME_TAKEN');
step('duplicate email / username rejected');

r = await api('GET', `/api/users/search?q=bob_${run.slice(0, 3)}`, { token: alice.token });
assert.ok(r.users.some((u) => u.id === bob.id));
r = await api('GET', `/api/users/search?q=${encodeURIComponent(bob.email.toUpperCase())}`, { token: alice.token });
assert.equal(r.users[0].id, bob.id);
step('search by username prefix and by email');

const sa = io(API, { auth: { token: alice.token }, transports: ['websocket'] });
const sb = io(API, { auth: { token: bob.token }, transports: ['websocket'] });
await Promise.all([waitFor(sa, 'connect'), waitFor(sb, 'connect')]).catch(() => {});

const inviteEvt = waitFor(sb, 'invite:new');
r = await api('POST', '/api/invites', { token: alice.token, body: { userId: bob.id } });
assert.equal(r.status, 201, JSON.stringify(r));
await inviteEvt;
r = await api('POST', '/api/invites', { token: alice.token, body: { userId: bob.id } });
assert.equal(r.error.code, 'INVITE_ALREADY_SENT');
r = await api('GET', '/api/invites', { token: bob.token });
assert.equal(r.incoming.length, 1);
const chatEvt = waitFor(sa, 'chat:new');
r = await api('POST', `/api/invites/${r.incoming[0].id}/accept`, { token: bob.token });
const chatId = r.chat.id;
await chatEvt;
r = await api('POST', '/api/invites', { token: alice.token, body: { userId: bob.id } });
assert.equal(r.error.code, 'ALREADY_IN_CHATS');
step('invite → realtime → accept → chat created');

const typing = waitFor(sb, 'typing');
sa.emit('typing', { chatId, isTyping: true });
assert.equal((await typing).isTyping, true);
step('typing indicator');

sb.on('message:new', ({ message }) => {
  if (message.senderId !== bob.id) sb.emit('message:delivered', { messageIds: [message.id] });
});
const delivered = waitFor(sa, 'message:status', (d) => d.status === 'delivered');
r = await api('POST', `/api/chats/${chatId}/messages`, { token: alice.token, body: { clientId: 'c1', type: 'text', text: 'Hello Bob 👋' } });
assert.equal(r.status, 201);
const msgId = r.message.id;
await delivered;
r = await api('POST', `/api/chats/${chatId}/messages`, { token: alice.token, body: { clientId: 'c1', type: 'text', text: 'Hello Bob 👋' } });
assert.equal(r.message.id, msgId); // idempotent retry
const readEvt = waitFor(sa, 'message:status', (d) => d.status === 'read');
await api('POST', `/api/chats/${chatId}/read`, { token: bob.token });
await readEvt;
step('send → delivered → read (+ idempotent retry)');

r = await api('PATCH', `/api/messages/${msgId}`, { token: bob.token, body: { text: 'hack' } });
assert.equal(r.status, 403);
r = await api('PATCH', `/api/messages/${msgId}`, { token: alice.token, body: { text: 'Hello Bob (edited)' } });
assert.ok(r.message.editedAt);
r = await api('DELETE', `/api/messages/${msgId}`, { token: alice.token });
assert.ok(r.message.deletedAt);
assert.equal(r.message.text, null);
step('edit / delete own messages only');

// 1x1 PNG
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64');
let form = new FormData();
form.append('file', new Blob([png], { type: 'image/png' }), 'a.png');
r = await api('PUT', '/api/me/avatar', { token: alice.token, form });
assert.ok(r.user.avatarUrl, JSON.stringify(r));
const img = await fetch(API + r.user.avatarUrl);
assert.equal(img.status, 200);
assert.ok(Buffer.from(await img.arrayBuffer()).equals(png));
form = new FormData();
form.append('file', new Blob([Buffer.from('GIF89a....')], { type: 'image/gif' }), 'a.gif');
r = await api('PUT', '/api/me/avatar', { token: alice.token, form });
assert.equal(r.error.code, 'UNSUPPORTED_FORMAT');
form = new FormData();
form.append('file', new Blob([Buffer.alloc(5 * 1024 * 1024 + 10)], { type: 'image/png' }), 'big.png');
r = await api('PUT', '/api/me/avatar', { token: alice.token, form });
assert.equal(r.error.code, 'FILE_TOO_LARGE');
r = await api('PATCH', '/api/me', { token: alice.token, body: { about: 'Hi, I am Alice' } });
assert.equal(r.user.about, 'Hi, I am Alice');
step('profile: avatar PNG ok, GIF rejected, >5MB rejected, about updated');

form = new FormData();
form.append('kind', 'image');
form.append('file', new Blob([png], { type: 'image/png' }), 'p.png');
r = await api('POST', '/api/media', { token: alice.token, form });
assert.equal(r.status, 201);
r = await api('POST', `/api/chats/${chatId}/messages`, { token: alice.token, body: { clientId: 'c2', type: 'image', mediaId: r.media.id, meta: { width: 1, height: 1 } } });
assert.equal(r.status, 201);
const range = await fetch(API + r.message.media.url, { headers: { Range: 'bytes=0-3' } });
assert.equal(range.status, 206);
step('image message + ranged download');

r = await api('PATCH', `/api/chats/${chatId}`, { token: alice.token, body: { archived: true, muted: true } });
assert.equal(r.chat.archived, true);
r = await api('GET', '/api/chats?archived=false', { token: alice.token });
assert.equal(r.chats.length, 0);
r = await api('PATCH', `/api/chats/${chatId}`, { token: alice.token, body: { archived: false } });
r = await api('GET', '/api/chats', { token: alice.token });
assert.equal(r.chats[0].lastMessage.type, 'image');
step('archive / unarchive / mute + chat list');

r = await api('POST', '/api/auth/refresh', { body: { refreshToken: alice.refresh } });
assert.ok(r.tokens.accessToken);
const r2 = await api('POST', '/api/auth/refresh', { body: { refreshToken: alice.refresh } });
assert.equal(r2.error.code, 'SESSION_EXPIRED');
step('refresh token rotation');

await api('POST', '/api/auth/forgot-password', { body: { email: bob.email } });
await new Promise((res) => setTimeout(res, 500));
const resetCode = await (async () => {
  const s = await fetch(`${MAIL}/api/v1/search?query=${encodeURIComponent(`to:${bob.email} subject:"Reset"`)}`).then((x) => x.json());
  const msg = await fetch(`${MAIL}/api/v1/message/${s.messages[0].ID}`).then((x) => x.json());
  return /\b(\d{6})\b/.exec(msg.Text)[1];
})();
r = await api('POST', '/api/auth/reset-password', { body: { email: bob.email, code: resetCode, password: 'N3w!Password' } });
assert.equal(r.ok, true, JSON.stringify(r));
r = await api('POST', '/api/auth/login', { body: { email: bob.email, password: 'N3w!Password' } });
assert.ok(r.tokens);
step('password reset via email code');

sa.close();
sb.close();
console.log('\nAll smoke tests passed.');
process.exit(0);
