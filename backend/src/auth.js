import crypto from 'node:crypto';
import jwt from 'jsonwebtoken';
import { config } from './config.js';
import { query } from './db.js';
import { ApiError } from './errors.js';
import { encrypt, jwtSecret, sha256 } from './crypto.js';

export function signAccessToken(userId, sessionId) {
  return jwt.sign({ sub: userId, sid: sessionId }, jwtSecret, { expiresIn: config.accessTokenTtlSec });
}

export function verifyAccessToken(token) {
  return jwt.verify(token, jwtSecret);
}

async function issueTokens(userId, sessionId) {
  const refreshToken = crypto.randomBytes(48).toString('base64url');
  const expiresAt = new Date(Date.now() + config.refreshTokenTtlDays * 86400_000);
  return { refreshToken, expiresAt, accessToken: signAccessToken(userId, sessionId), refreshHash: sha256(refreshToken) };
}

const tokenResponse = (t) => ({
  accessToken: t.accessToken,
  refreshToken: t.refreshToken,
  accessTokenExpiresIn: config.accessTokenTtlSec,
  refreshTokenExpiresAt: t.expiresAt.toISOString(),
});

export async function createSession(userId, device) {
  const id = crypto.randomUUID();
  const t = await issueTokens(userId, id);
  await query(
    'INSERT INTO sessions (id, user_id, refresh_hash, device_enc, expires_at) VALUES ($1,$2,$3,$4,$5)',
    [id, userId, t.refreshHash, device ? encrypt(device) : null, t.expiresAt],
  );
  return tokenResponse(t);
}

/**
 * Refresh-token rotation with a sliding 30-day expiry. Each refresh issues a new refresh token;
 * the previous one stays valid for a 2-minute grace period so a lost response (app killed,
 * network drop) does not log the user out.
 */
export async function rotateSession(refreshToken) {
  const hash = sha256(refreshToken);
  const { rows } = await query(
    `SELECT id, user_id, refresh_hash FROM sessions
     WHERE revoked_at IS NULL AND expires_at > now()
       AND (refresh_hash = $1 OR (prev_refresh_hash = $1 AND rotated_at > now() - interval '2 minutes'))`,
    [hash],
  );
  if (!rows.length) throw new ApiError(401, 'SESSION_EXPIRED', 'Your session has expired. Please log in again.');
  const s = rows[0];
  const t = await issueTokens(s.user_id, s.id);
  // When the grace token is used, keep the original "previous" hash so the window is not extended.
  const prev = s.refresh_hash === hash ? hash : null;
  await query(
    `UPDATE sessions SET refresh_hash=$2, expires_at=$3, last_used_at=now(),
       prev_refresh_hash = COALESCE($4, prev_refresh_hash), rotated_at = CASE WHEN $4::text IS NULL THEN rotated_at ELSE now() END
     WHERE id=$1`,
    [s.id, t.refreshHash, t.expiresAt, prev],
  );
  return { userId: s.user_id, tokens: tokenResponse(t) };
}

export async function revokeSessionByRefresh(refreshToken) {
  await query('UPDATE sessions SET revoked_at=now() WHERE refresh_hash=$1 AND revoked_at IS NULL', [sha256(refreshToken)]);
}

export async function revokeAllSessions(userId, exceptSessionId = null) {
  await query('UPDATE sessions SET revoked_at=now() WHERE user_id=$1 AND revoked_at IS NULL AND id IS DISTINCT FROM $2', [
    userId,
    exceptSessionId,
  ]);
}

export async function isSessionActive(sessionId) {
  const { rows } = await query('SELECT 1 FROM sessions WHERE id=$1 AND revoked_at IS NULL AND expires_at > now()', [
    sessionId,
  ]);
  return rows.length > 0;
}

/** Express middleware: requires "Authorization: Bearer <access token>". */
export function requireAuth(req, _res, next) {
  const header = req.headers.authorization || '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) return next(new ApiError(401, 'UNAUTHORIZED', 'Authentication required'));
  try {
    const payload = verifyAccessToken(token);
    req.userId = payload.sub;
    req.sessionId = payload.sid;
    next();
  } catch (e) {
    const expired = e.name === 'TokenExpiredError';
    next(new ApiError(401, expired ? 'TOKEN_EXPIRED' : 'UNAUTHORIZED', expired ? 'Access token expired' : 'Invalid token'));
  }
}
