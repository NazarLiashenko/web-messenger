import http from 'node:http';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import { config } from './config.js';
import { migrate, waitForDb } from './db.js';
import { errorHandler } from './errors.js';
import { initRealtime } from './realtime.js';
import { initPush, pushEnabled } from './push.js';
import authRoutes from './routes/auth.js';
import meRoutes from './routes/me.js';
import userRoutes from './routes/users.js';
import inviteRoutes from './routes/invites.js';
import groupRoutes from './routes/groups.js';
import { chatPollsRouter, pollsRouter } from './routes/polls.js';
import mediaRoutes from './routes/media.js';
import { chatsRouter, messagesRouter } from './routes/chats.js';

const app = express();
app.set('trust proxy', true);
app.use(helmet({ crossOriginResourcePolicy: { policy: 'cross-origin' } }));
app.use(cors()); // the future web client is served from a different origin
app.use(express.json({ limit: '1mb' }));
if (process.env.LOG_REQUESTS !== 'false') {
  app.use((req, res, next) => {
    const start = Date.now();
    res.on('finish', () => console.log(`[http] ${req.method} ${req.originalUrl.split('?')[0]} ${res.statusCode} ${Date.now() - start}ms`));
    next();
  });
}

app.get('/api/health', (_req, res) => res.json({ ok: true, push: pushEnabled(), time: new Date().toISOString() }));
app.use('/api/auth', authRoutes);
app.use('/api/me', meRoutes);
app.use('/api/users', userRoutes);
app.use('/api/invites', inviteRoutes);
app.use('/api/groups', groupRoutes);
app.use('/api/chats', chatPollsRouter);
app.use('/api/chats', chatsRouter);
app.use('/api/polls', pollsRouter);
app.use('/api/messages', messagesRouter);
app.use('/api/media', mediaRoutes);
app.use('/api', (_req, res) => res.status(404).json({ error: { code: 'NOT_FOUND', message: 'Unknown endpoint' } }));
app.get('/', (_req, res) => res.type('text').send('Messenger API is running. See /api/health'));
app.use(errorHandler);

async function main() {
  await waitForDb();
  await migrate();
  await initPush();
  const server = http.createServer(app);
  initRealtime(server);
  server.listen(config.port, () => console.log(`[api] listening on :${config.port}`));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
