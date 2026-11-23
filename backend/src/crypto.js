import crypto from 'node:crypto';
import { config } from './config.js';

/*
 * Encryption at rest.
 *  - AES-256-GCM (authenticated encryption) with a random 96-bit IV per value.
 *  - Independent sub-keys are derived from the master key with HKDF-SHA256.
 *  - Blind indexes (HMAC-SHA256) allow equality lookups on encrypted data
 *    (email, username, chat membership) without storing plaintext.
 */
const derive = (info) => Buffer.from(crypto.hkdfSync('sha256', config.masterKey, Buffer.alloc(0), info, 32));

const keys = {
  enc: derive('messenger/enc/v1'),
  file: derive('messenger/file/v1'),
  index: derive('messenger/index/v1'),
  sign: derive('messenger/sign/v1'),
  jwt: derive('messenger/jwt/v1'),
  code: derive('messenger/code/v1'),
};

export const jwtSecret = keys.jwt;

const VERSION = 'v1';

export function encrypt(plain) {
  if (plain === null || plain === undefined) return null;
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', keys.enc, iv);
  const ct = Buffer.concat([cipher.update(String(plain), 'utf8'), cipher.final()]);
  return `${VERSION}:${Buffer.concat([iv, cipher.getAuthTag(), ct]).toString('base64')}`;
}

export function decrypt(value) {
  if (value === null || value === undefined) return null;
  const [version, payload] = value.split(':');
  if (version !== VERSION) throw new Error('Unknown ciphertext version');
  const buf = Buffer.from(payload, 'base64');
  const decipher = crypto.createDecipheriv('aes-256-gcm', keys.enc, buf.subarray(0, 12));
  decipher.setAuthTag(buf.subarray(12, 28));
  return Buffer.concat([decipher.update(buf.subarray(28)), decipher.final()]).toString('utf8');
}

export const encryptJson = (obj) => (obj == null ? null : encrypt(JSON.stringify(obj)));
export const decryptJson = (v) => (v == null ? null : JSON.parse(decrypt(v)));

/** Binary encryption for media files: [12 bytes IV][16 bytes tag][ciphertext]. */
export function encryptBuffer(buf) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', keys.file, iv);
  const ct = Buffer.concat([cipher.update(buf), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ct]);
}

export function decryptBuffer(buf) {
  const decipher = crypto.createDecipheriv('aes-256-gcm', keys.file, buf.subarray(0, 12));
  decipher.setAuthTag(buf.subarray(12, 28));
  return Buffer.concat([decipher.update(buf.subarray(28)), decipher.final()]);
}

/** Deterministic keyed hash for lookups on encrypted data. */
export const blindIndex = (value, domain) =>
  crypto.createHmac('sha256', keys.index).update(`${domain}:${value}`).digest('base64url');

export const emailIndex = (email) => blindIndex(email.trim().toLowerCase(), 'email');
export const usernameIndex = (username) => blindIndex(username.trim().toLowerCase(), 'username');
export const userKey = (userId) => blindIndex(userId, 'member');
export const pairKey = (a, b) => blindIndex([a, b].sort().join(':'), 'pair');

/** Prefix tokens so users can be found by the beginning of their username. */
export function usernameSearchTokens(username) {
  const u = username.trim().toLowerCase();
  const tokens = new Set();
  for (let i = 1; i <= u.length; i++) tokens.add(blindIndex(u.slice(0, i), 'uprefix'));
  return [...tokens];
}
export const usernamePrefixToken = (q) => blindIndex(q.trim().toLowerCase(), 'uprefix');

export const hashCode = (code) => crypto.createHmac('sha256', keys.code).update(code).digest('base64url');
export const sha256 = (v) => crypto.createHash('sha256').update(v).digest('base64url');
export const randomCode = () => crypto.randomInt(0, 1_000_000).toString().padStart(6, '0');

/** Signed, expiring media URLs (usable by <img>/<video> on web and by native players). */
export const signMedia = (mediaId, exp) =>
  crypto.createHmac('sha256', keys.sign).update(`${mediaId}.${exp}`).digest('base64url');

export function verifyMediaSig(mediaId, exp, sig) {
  if (!exp || !sig || Number(exp) < Date.now() / 1000) return false;
  const expected = Buffer.from(signMedia(mediaId, exp));
  const given = Buffer.from(String(sig));
  return expected.length === given.length && crypto.timingSafeEqual(expected, given);
}

/* Password hashing with scrypt (built into Node, no native deps). */
const SCRYPT = { N: 16384, r: 8, p: 1, keylen: 64 };

export function hashPassword(password) {
  return new Promise((resolve, reject) => {
    const salt = crypto.randomBytes(16);
    crypto.scrypt(password, salt, SCRYPT.keylen, { N: SCRYPT.N, r: SCRYPT.r, p: SCRYPT.p }, (err, key) => {
      if (err) return reject(err);
      resolve(`scrypt$${SCRYPT.N}$${SCRYPT.r}$${SCRYPT.p}$${salt.toString('base64')}$${key.toString('base64')}`);
    });
  });
}

export function verifyPassword(password, stored) {
  return new Promise((resolve) => {
    const [alg, N, r, p, salt, hash] = stored.split('$');
    if (alg !== 'scrypt') return resolve(false);
    const expected = Buffer.from(hash, 'base64');
    crypto.scrypt(password, Buffer.from(salt, 'base64'), expected.length, { N: +N, r: +r, p: +p }, (err, key) => {
      if (err) return resolve(false);
      resolve(crypto.timingSafeEqual(key, expected));
    });
  });
}
