import { Router } from 'express';
import { z } from 'zod';
import { config } from '../config.js';
import { verifyMediaSig } from '../crypto.js';
import { ApiError, notFound, parse } from '../errors.js';
import { requireAuth } from '../auth.js';
import { singleUpload } from '../upload.js';
import { mediaUrl, readMedia, resolveMime, storeMedia } from '../services/media.js';

const router = Router();

/** Upload a chat attachment (image / video / audio, max 20 MB). Encrypted before it touches the disk. */
router.post('/', requireAuth, singleUpload(config.limits.mediaBytes, 'Attachment'), async (req, res) => {
  const { kind } = parse(z.object({ kind: z.enum(['image', 'video', 'audio']) }), req.body);
  const mime = resolveMime(req.file, kind);
  const media = await storeMedia({ ownerId: req.userId, kind, mime, buffer: req.file.buffer });
  res.status(201).json({ media: { ...media, url: mediaUrl(media.id) } });
});

/**
 * Download (decrypted on the fly). Authorised by a signed, expiring URL that is only handed out
 * to chat members / contacts. Supports HTTP Range requests for audio / video seeking.
 */
router.get('/:id', async (req, res) => {
  const { id } = req.params;
  if (!verifyMediaSig(id, req.query.exp, req.query.sig)) throw new ApiError(403, 'FORBIDDEN', 'Invalid or expired media link');
  const media = await readMedia(id);
  if (!media) throw notFound('Media');
  const total = media.data.length;
  res.setHeader('Content-Type', media.mime);
  res.setHeader('Accept-Ranges', 'bytes');
  res.setHeader('Cache-Control', 'private, max-age=86400');
  res.setHeader('Cross-Origin-Resource-Policy', 'cross-origin');

  const range = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range || '');
  if (range) {
    let start = range[1] === '' ? total - Number(range[2]) : Number(range[1]);
    let end = range[1] !== '' && range[2] !== '' ? Number(range[2]) : total - 1;
    start = Math.max(0, start);
    end = Math.min(end, total - 1);
    if (start > end) {
      res.setHeader('Content-Range', `bytes */${total}`);
      return res.status(416).end();
    }
    res.status(206);
    res.setHeader('Content-Range', `bytes ${start}-${end}/${total}`);
    res.setHeader('Content-Length', end - start + 1);
    return res.end(media.data.subarray(start, end + 1));
  }
  res.setHeader('Content-Length', total);
  res.end(media.data);
});

export default router;
