import fs from 'node:fs';
import { config } from './config.js';
import { query } from './db.js';
import { decrypt } from './crypto.js';

/*
 * Firebase Cloud Messaging (optional).
 * Enabled when a service-account JSON is present (FIREBASE_SERVICE_ACCOUNT or data/firebase-service-account.json).
 * Without it, clients still get in-app / system notifications through the realtime socket.
 */
let messaging = null;

export async function initPush() {
  if (!fs.existsSync(config.firebaseServiceAccount)) {
    console.log('[push] FCM disabled (no service account). Socket-based notifications only.');
    return;
  }
  try {
    const { initializeApp, cert } = await import('firebase-admin/app');
    const { getMessaging } = await import('firebase-admin/messaging');
    const app = initializeApp({ credential: cert(JSON.parse(fs.readFileSync(config.firebaseServiceAccount, 'utf8'))) });
    messaging = getMessaging(app);
    console.log('[push] FCM enabled');
  } catch (e) {
    console.error('[push] failed to initialise FCM:', e.message);
  }
}

export const pushEnabled = () => messaging !== null;

/** Sends a push to every registered device of the user. Never throws. */
export async function pushToUser(userId, { title, body, data = {} }) {
  if (!messaging) return;
  try {
    const { rows } = await query('SELECT token_hash, token_enc FROM push_tokens WHERE user_id=$1', [userId]);
    if (!rows.length) return;
    const tokens = rows.map((r) => decrypt(r.token_enc));
    const res = await messaging.sendEachForMulticast({
      tokens,
      notification: { title, body },
      data: Object.fromEntries(Object.entries(data).map(([k, v]) => [k, String(v)])),
      android: { priority: 'high', notification: { channelId: data.type === 'invite' ? 'invites' : 'messages' } },
    });
    const stale = res.responses
      .map((r, i) => (!r.success && /registration-token-not-registered|invalid-argument/.test(r.error?.code || '') ? rows[i].token_hash : null))
      .filter(Boolean);
    if (stale.length) await query('DELETE FROM push_tokens WHERE token_hash = ANY($1)', [stale]);
  } catch (e) {
    console.error('[push] send failed:', e.message);
  }
}
