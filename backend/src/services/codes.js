import crypto from 'node:crypto';
import { config } from '../config.js';
import { query } from '../db.js';
import { hashCode, randomCode } from '../crypto.js';
import { ApiError, badRequest } from '../errors.js';
import { sendCode } from '../mailer.js';

const RESEND_COOLDOWN_SEC = 30;
const MAX_ATTEMPTS = 5;

/** Creates a one-time 6-digit code, invalidates older ones and emails it. */
export async function issueCode(userId, email, purpose, { enforceCooldown = true } = {}) {
  if (enforceCooldown) {
    const { rows } = await query(
      `SELECT EXTRACT(EPOCH FROM (now() - created_at))::int AS age FROM email_codes
       WHERE user_id=$1 AND purpose=$2 ORDER BY created_at DESC LIMIT 1`,
      [userId, purpose],
    );
    if (rows.length && rows[0].age < RESEND_COOLDOWN_SEC) {
      throw new ApiError(429, 'TOO_SOON', `Please wait ${RESEND_COOLDOWN_SEC - rows[0].age}s before requesting a new code`, {
        retryAfter: RESEND_COOLDOWN_SEC - rows[0].age,
      });
    }
  }
  const code = randomCode();
  await query('UPDATE email_codes SET consumed_at=now() WHERE user_id=$1 AND purpose=$2 AND consumed_at IS NULL', [
    userId,
    purpose,
  ]);
  await query(
    `INSERT INTO email_codes (id, user_id, purpose, code_hash, expires_at)
     VALUES ($1,$2,$3,$4, now() + make_interval(mins => $5))`,
    [crypto.randomUUID(), userId, purpose, hashCode(code), config.codeTtlMin],
  );
  return sendCode(email, purpose, code);
}

/** Checks and consumes a code. Throws a 400 with a specific error code on failure. */
export async function consumeCode(userId, purpose, code) {
  const { rows } = await query(
    `SELECT id, code_hash, attempts, expires_at < now() AS expired FROM email_codes
     WHERE user_id=$1 AND purpose=$2 AND consumed_at IS NULL ORDER BY created_at DESC LIMIT 1`,
    [userId, purpose],
  );
  const row = rows[0];
  if (!row) throw badRequest('INVALID_CODE', 'No active code. Request a new one.', { field: 'code' });
  if (row.expired) throw badRequest('CODE_EXPIRED', 'The code has expired. Request a new one.', { field: 'code' });
  if (row.attempts >= MAX_ATTEMPTS) {
    throw badRequest('TOO_MANY_ATTEMPTS', 'Too many wrong attempts. Request a new code.', { field: 'code' });
  }
  const a = Buffer.from(row.code_hash);
  const b = Buffer.from(hashCode(String(code).trim()));
  if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) {
    await query('UPDATE email_codes SET attempts = attempts + 1 WHERE id=$1', [row.id]);
    throw badRequest('INVALID_CODE', 'The code is incorrect', { field: 'code' });
  }
  // Atomic consume: a code can only ever be used once, even with concurrent requests.
  const consumed = await query('UPDATE email_codes SET consumed_at=now() WHERE id=$1 AND consumed_at IS NULL RETURNING id', [
    row.id,
  ]);
  if (!consumed.rows.length) throw badRequest('INVALID_CODE', 'The code was already used', { field: 'code' });
}
