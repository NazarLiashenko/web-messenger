import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
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
const webIndex = config.webDir ? path.join(config.webDir, 'index.html') : '';
const serveWeb = !!webIndex && fs.existsSync(webIndex);

app.use(
  helmet({
    crossOriginResourcePolicy: { policy: 'cross-origin' },
    // Policy for the Flutter web app: own scripts only (no inline / eval; WebAssembly for CanvasKit),
    // Roboto / Noto fallback fonts from Google, API + WebSocket to this or another configured server.
    contentSecurityPolicy: {
      useDefaults: false,
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'", "'wasm-unsafe-eval'"],
        styleSrc: ["'self'", "'unsafe-inline'"],
        imgSrc: ["'self'", 'data:', 'blob:', 'https:'],
        mediaSrc: ["'self'", 'blob:', 'https:'],
        fontSrc: ["'self'", 'data:', 'https://fonts.gstatic.com'],
        connectSrc: ["'self'", 'https:', 'wss:', 'ws:', 'data:', 'blob:'],
        workerSrc: ["'self'", 'blob:'],
        manifestSrc: ["'self'"],
        objectSrc: ["'none'"],
        baseUri: ["'self'"],
        formAction: ["'self'"],
        frameAncestors: ["'none'"],
      },
    },
  }),
);
app.use(cors()); // the mobile app and web builds served elsewhere may call the API from other origins
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
if (serveWeb) {
  // The web app is served from the same origin as the API, so it needs no configuration and no CORS.
  const noCache = (file) => /(index\.html|flutter_bootstrap\.js|version\.json|manifest\.json|flutter_service_worker\.js)$/.test(file);
  app.use(
    express.static(config.webDir, {
      index: false,
      maxAge: '7d',
      setHeaders: (res, file) => noCache(file) && res.setHeader('Cache-Control', 'no-cache'),
    }),
  );
  // Any other non-API path is a client-side route: answer with the app shell.
  app.get(/^\/(?!api\/|socket\.io\/).*/, (_req, res) => {
    res.setHeader('Cache-Control', 'no-cache');
    res.sendFile(webIndex);
  });
  console.log(`[web] serving the web app from ${config.webDir}`);
} else {
  app.get('/', (_req, res) => res.type('text').send('Messenger API is running. See /api/health'));
}
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
