import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { config } from '../config.js';
import { query } from '../db.js';
import { decryptBuffer, encryptBuffer, signMedia } from '../crypto.js';
import { badRequest } from '../errors.js';

/** Allowed MIME types per media kind. */
export const ALLOWED_MIME = {
  avatar: ['image/jpeg', 'image/png'],
  image: ['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/heic', 'image/heif'],
  video: ['video/mp4', 'video/quicktime', 'video/webm', 'video/3gpp', 'video/x-matroska'],
  audio: ['audio/mp4', 'audio/m4a', 'audio/x-m4a', 'audio/aac', 'audio/mpeg', 'audio/ogg', 'audio/webm', 'audio/wav', 'audio/x-wav', 'audio/opus'],
};

const EXT_MIME = {
  jpg: 'image/jpeg', jpeg: 'image/jpeg', png: 'image/png', gif: 'image/gif', webp: 'image/webp', heic: 'image/heic',
  mp4: 'video/mp4', mov: 'video/quicktime', webm: 'video/webm', '3gp': 'video/3gpp', mkv: 'video/x-matroska',
  m4a: 'audio/mp4', aac: 'audio/aac', mp3: 'audio/mpeg', ogg: 'audio/ogg', oga: 'audio/ogg', wav: 'audio/wav', opus: 'audio/opus',
};

/** Detects JPEG / PNG by magic bytes (used to validate avatar uploads). */
export function sniffImage(buf) {
  if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf.length > 8 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';
  return null;
}

export function resolveMime(file, kind) {
  let mime = (file.mimetype || '').toLowerCase();
  if (!mime || mime === 'application/octet-stream') {
    const ext = path.extname(file.originalname || '').slice(1).toLowerCase();
    mime = EXT_MIME[ext] || mime;
  }
  if (kind === 'audio' && mime === 'video/mp4') mime = 'audio/mp4'; // m4a recordings are often labelled video/mp4
  if (kind === 'avatar' || kind === 'image') {
    const sniffed = sniffImage(file.buffer);
    if (sniffed) mime = sniffed;
    else if (kind === 'avatar') throw badRequest('UNSUPPORTED_FORMAT', 'Profile picture must be a JPEG or PNG image');
  }
  if (!ALLOWED_MIME[kind].includes(mime)) {
    throw badRequest('UNSUPPORTED_FORMAT', `Unsupported ${kind} format (${mime || 'unknown'})`);
  }
  return mime;
}

/*
 * Encrypted media storage. MEDIA_STORAGE=fs (default): files on the data volume.
 * MEDIA_STORAGE=db: bytes in the media_blobs table (hosts without a persistent disk).
 * Either way only AES-256-GCM ciphertext is stored; storage_path 'db:' marks database blobs.
 */
const DB_PATH = 'db:';

/** Encrypts and stores an uploaded file. */
export async function storeMedia({ ownerId, kind, mime, buffer }) {
  const id = crypto.randomUUID();
  const encrypted = encryptBuffer(buffer);
  let rel = DB_PATH;
  if (config.mediaStorage !== 'db') {
    rel = path.join(id.slice(0, 2), `${id}.bin`);
    const abs = path.join(config.mediaDir, rel);
    await fs.mkdir(path.dirname(abs), { recursive: true });
    await fs.writeFile(abs, encrypted);
  }
  await query('INSERT INTO media (id, owner_id, kind, mime, size, storage_path) VALUES ($1,$2,$3,$4,$5,$6)', [
    id,
    ownerId,
    kind,
    mime,
    buffer.length,
    rel,
  ]);
  if (rel === DB_PATH) await query('INSERT INTO media_blobs (media_id, data) VALUES ($1,$2)', [id, encrypted]);
  return { id, kind, mime, size: buffer.length };
}

export async function readMedia(id) {
  const { rows } = await query(
    'SELECT m.*, b.data AS blob FROM media m LEFT JOIN media_blobs b ON b.media_id = m.id WHERE m.id=$1',
    [id],
  );
  if (!rows.length) return null;
  const { blob, ...row } = rows[0];
  const encrypted = row.storage_path === DB_PATH ? blob : await fs.readFile(path.join(config.mediaDir, row.storage_path));
  return { ...row, data: decryptBuffer(encrypted) };
}

export async function deleteMedia(id) {
  if (!id) return;
  const { rows } = await query('DELETE FROM media WHERE id=$1 RETURNING storage_path', [id]); // blob row cascades
  if (rows.length && rows[0].storage_path !== DB_PATH) {
    await fs.rm(path.join(config.mediaDir, rows[0].storage_path), { force: true });
  }
}

/**
 * Signed media URL (relative to the API origin). Expiry is aligned to whole days so the
 * URL stays stable for a while and clients can cache images by URL.
 */
export function mediaUrl(id) {
  if (!id) return null;
  const exp = (Math.floor(Date.now() / 1000 / 86400) + 2) * 86400;
  return `/api/media/${id}?exp=${exp}&sig=${signMedia(id, exp)}`;
}
