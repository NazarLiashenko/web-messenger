import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const env = process.env;

const dataDir = env.DATA_DIR || path.resolve('data');
fs.mkdirSync(dataDir, { recursive: true });

/**
 * Master key used to derive all encryption / HMAC / signing keys.
 * Taken from MASTER_KEY (base64, 32 bytes) or generated once and persisted
 * in the data volume, so `docker compose up` works without any manual setup.
 */
function loadMasterKey() {
  if (!env.MASTER_KEY && env.RENDER) {
    // Render's disk is wiped on every deploy: a generated key would be lost and all data unreadable.
    throw new Error('MASTER_KEY must be set on Render (base64 of 32 random bytes)');
  }
  if (env.MASTER_KEY) {
    const key = Buffer.from(env.MASTER_KEY, 'base64');
    if (key.length !== 32) throw new Error('MASTER_KEY must be 32 bytes encoded as base64');
    return key;
  }
  const keyFile = path.join(dataDir, 'master.key');
  if (fs.existsSync(keyFile)) return Buffer.from(fs.readFileSync(keyFile, 'utf8').trim(), 'base64');
  const key = crypto.randomBytes(32);
  fs.writeFileSync(keyFile, key.toString('base64'), { mode: 0o600 });
  console.log(`[config] generated new master key at ${keyFile}`);
  return key;
}

const int = (v, d) => (v === undefined || v === '' ? d : parseInt(v, 10));

export const config = {
  port: int(env.PORT, 3000),
  databaseUrl: env.DATABASE_URL || 'postgres://messenger:messenger@localhost:5432/messenger',
  dataDir,
  mediaDir: path.join(dataDir, 'media'),
  mediaStorage: env.MEDIA_STORAGE === 'db' ? 'db' : 'fs',
  // Built Flutter web app served from the same origin as the API (production image).
  webDir: env.WEB_DIR || '',
  dbPoolMax: int(env.DB_POOL_MAX, 20),
  brevoApiKey: env.BREVO_API_KEY || '',
  masterKey: loadMasterKey(),
  accessTokenTtlSec: int(env.ACCESS_TOKEN_TTL_SEC, 15 * 60),
  refreshTokenTtlDays: int(env.REFRESH_TOKEN_TTL_DAYS, 30),
  codeTtlMin: int(env.CODE_TTL_MIN, 15),
  limits: {
    avatarBytes: 5 * 1024 * 1024,
    mediaBytes: 20 * 1024 * 1024,
  },
  smtp: {
    host: env.SMTP_HOST || 'localhost',
    port: int(env.SMTP_PORT, 1025),
    secure: env.SMTP_SECURE === 'true',
    user: env.SMTP_USER || '',
    pass: env.SMTP_PASS || '',
    from: env.MAIL_FROM || 'Messenger <no-reply@messenger.local>',
  },
  firebaseServiceAccount: env.FIREBASE_SERVICE_ACCOUNT || path.join(dataDir, 'firebase-service-account.json'),
  // Prints verification / reset codes to the server log (handy for reviewers).
  logEmailCodes: env.LOG_EMAIL_CODES !== 'false',
};

fs.mkdirSync(config.mediaDir, { recursive: true });
