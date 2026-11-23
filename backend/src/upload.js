import multer from 'multer';
import { ApiError } from './errors.js';

/** Single-file multipart upload ("file" field) kept in memory, with a friendly size error. */
export function singleUpload(maxBytes, label) {
  const handler = multer({ storage: multer.memoryStorage(), limits: { fileSize: maxBytes, files: 1 } }).single('file');
  return (req, res, next) =>
    handler(req, res, (err) => {
      if (err?.code === 'LIMIT_FILE_SIZE') {
        return next(
          new ApiError(413, 'FILE_TOO_LARGE', `${label} must be at most ${Math.round(maxBytes / 1024 / 1024)} MB`, {
            maxBytes,
          }),
        );
      }
      if (err) return next(new ApiError(400, 'UPLOAD_FAILED', err.message));
      if (!req.file) return next(new ApiError(400, 'VALIDATION_ERROR', 'No file uploaded', { field: 'file' }));
      next();
    });
}
