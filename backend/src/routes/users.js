import { Router } from 'express';
import { query } from '../db.js';
import { emailIndex, pairKey, userKey, usernameIndex, usernamePrefixToken } from '../crypto.js';
import { notFound } from '../errors.js';
import { requireAuth } from '../auth.js';
import { serializeUser } from '../services/users.js';

const router = Router();
router.use(requireAuth);

/** Adds the relationship with the current user: existing chat id and/or pending invite. */
async function withRelations(me, users) {
  if (!users.length) return [];
  const pairs = users.map((u) => pairKey(me, u.id));
  const [chats, invites] = await Promise.all([
    query('SELECT id, pair_key FROM chats WHERE pair_key = ANY($1)', [pairs]),
    query(`SELECT id, pair_key, from_key FROM invitations WHERE status='pending' AND pair_key = ANY($1)`, [pairs]),
  ]);
  const chatByPair = new Map(chats.rows.map((r) => [r.pair_key, r.id]));
  const inviteByPair = new Map(invites.rows.map((r) => [r.pair_key, r]));
  const myKey = userKey(me);
  return users.map((u, i) => {
    const inv = inviteByPair.get(pairs[i]);
    return {
      ...u,
      chatId: chatByPair.get(pairs[i]) || null,
      invite: inv ? { id: inv.id, direction: inv.from_key === myKey ? 'outgoing' : 'incoming' } : null,
    };
  });
}

/**
 * Search by email (exact, case-insensitive) or by username (case-insensitive prefix).
 * Works on blind indexes, so the database never sees plaintext usernames or emails.
 */
router.get('/search', async (req, res) => {
  const q = String(req.query.q || '').trim().replace(/^@/, '');
  if (q.length < 1) return res.json({ users: [] });
  let rows;
  if (q.includes('@')) {
    ({ rows } = await query('SELECT * FROM users WHERE email_hash=$1 AND email_verified AND id<>$2', [emailIndex(q), req.userId]));
  } else {
    ({ rows } = await query(
      `SELECT u.* FROM user_search_tokens t JOIN users u ON u.id = t.user_id
       WHERE t.token = $1 AND u.email_verified AND u.id <> $2
       ORDER BY (u.username_hash = $3) DESC, u.created_at LIMIT 30`,
      [usernamePrefixToken(q), req.userId, usernameIndex(q)],
    ));
  }
  const users = rows.map((r) => serializeUser(r)).sort((a, b) => a.username.length - b.username.length);
  res.json({ users: await withRelations(req.userId, users) });
});

router.get('/:id', async (req, res) => {
  if (!/^[0-9a-f-]{36}$/i.test(req.params.id)) throw notFound('User');
  const { rows } = await query('SELECT * FROM users WHERE id=$1', [req.params.id]);
  if (!rows.length) throw notFound('User');
  const [user] = await withRelations(req.userId, [serializeUser(rows[0])]);
  res.json({ user });
});

export default router;
