import { z } from 'zod';

/** Error with an HTTP status and a stable machine-readable code the clients can map to UI. */
export class ApiError extends Error {
  constructor(status, code, message, extra = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

export const badRequest = (code, message, extra) => new ApiError(400, code, message, extra);
export const notFound = (what = 'Resource') => new ApiError(404, 'NOT_FOUND', `${what} not found`);
export const forbidden = (message = 'Forbidden') => new ApiError(403, 'FORBIDDEN', message);

/** Validate input with a zod schema and turn failures into a 400 with the offending field. */
export function parse(schema, data) {
  const result = schema.safeParse(data ?? {});
  if (result.success) return result.data;
  const issue = result.error.issues[0];
  const field = issue.path.join('.') || undefined;
  throw badRequest('VALIDATION_ERROR', field ? `${field}: ${issue.message}` : issue.message, { field });
}

export function errorHandler(err, req, res, _next) {
  if (err instanceof ApiError) {
    return res.status(err.status).json({ error: { code: err.code, message: err.message, ...err.extra } });
  }
  if (err?.code === 'LIMIT_FILE_SIZE') {
    return res.status(413).json({ error: { code: 'FILE_TOO_LARGE', message: 'File is too large' } });
  }
  if (err?.type === 'entity.parse.failed') {
    return res.status(400).json({ error: { code: 'BAD_JSON', message: 'Malformed JSON body' } });
  }
  console.error('[error]', req.method, req.originalUrl, err);
  res.status(500).json({ error: { code: 'INTERNAL', message: 'Something went wrong on the server' } });
}

/* Shared validators */
export const PASSWORD_RULES = [
  { test: (p) => p.length >= 8, message: 'at least 8 characters' },
  { test: (p) => /[a-z]/.test(p), message: 'at least 1 lowercase letter' },
  { test: (p) => /[A-Z]/.test(p), message: 'at least 1 uppercase letter' },
  { test: (p) => /\d/.test(p), message: 'at least 1 digit' },
  { test: (p) => /[^A-Za-z0-9]/.test(p), message: 'at least 1 special character' },
];

export function assertStrongPassword(password, field = 'password') {
  const failed = PASSWORD_RULES.filter((r) => !r.test(password)).map((r) => r.message);
  if (failed.length || password.length > 128) {
    throw badRequest('WEAK_PASSWORD', `Password must contain ${failed.join(', ') || 'at most 128 characters'}`, {
      field,
      failed,
    });
  }
}

export const emailSchema = z
  .string()
  .trim()
  .max(254)
  .regex(/^[^\s@]+@[^\s@]+\.[^\s@]+$/, 'invalid email address');

export const usernameSchema = z
  .string()
  .trim()
  .min(3, 'must be at least 3 characters')
  .max(32, 'must be at most 32 characters')
  .regex(/^[A-Za-z0-9_.]+$/, 'only letters, digits, "_" and "." are allowed');

export const uuidSchema = z.string().regex(/^[0-9a-f-]{36}$/i, 'invalid id');
