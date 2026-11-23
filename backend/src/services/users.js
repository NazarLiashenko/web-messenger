import { query } from '../db.js';
import { decrypt, usernameSearchTokens } from '../crypto.js';
import { mediaUrl } from './media.js';
import { isOnline } from '../realtime.js';

/** Public representation of a user. Private fields (email) only for the user themself. */
export function serializeUser(row, { self = false } = {}) {
  const user = {
    id: row.id,
    username: decrypt(row.username_enc),
    about: row.about_enc ? decrypt(row.about_enc) : '',
    avatarUrl: mediaUrl(row.avatar_media_id),
    online: isOnline(row.id),
    lastSeenAt: row.last_seen_at,
    createdAt: row.created_at,
  };
  if (self) {
    user.email = decrypt(row.email_enc);
    user.emailVerified = row.email_verified;
    user.pendingEmail = row.pending_email_enc ? decrypt(row.pending_email_enc) : null;
  }
  return user;
}

export async function getUserRow(id) {
  const { rows } = await query('SELECT * FROM users WHERE id=$1', [id]);
  return rows[0] || null;
}

export async function getUsersByIds(ids) {
  const unique = [...new Set(ids)];
  if (!unique.length) return new Map();
  const { rows } = await query('SELECT * FROM users WHERE id = ANY($1::uuid[])', [unique]);
  return new Map(rows.map((r) => [r.id, serializeUser(r)]));
}

export async function replaceSearchTokens(client, userId, username) {
  await client.query('DELETE FROM user_search_tokens WHERE user_id=$1', [userId]);
  const tokens = usernameSearchTokens(username);
  await client.query(
    'INSERT INTO user_search_tokens (user_id, token) SELECT $1, unnest($2::text[]) ON CONFLICT DO NOTHING',
    [userId, tokens],
  );
}
