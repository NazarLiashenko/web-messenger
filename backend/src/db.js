import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import pg from 'pg';
import { config } from './config.js';

export const pool = new pg.Pool({ connectionString: config.databaseUrl, max: config.dbPoolMax });
// Hosted Postgres (Neon, …) closes idle connections; without this handler such an error would crash the process.
pool.on('error', (e) => console.error('[db] idle client error:', e.message));

export const query = (text, params) => pool.query(text, params);

export async function tx(fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (e) {
    await client.query('ROLLBACK');
    throw e;
  } finally {
    client.release();
  }
}

export async function waitForDb(retries = 30) {
  for (let i = 0; i < retries; i++) {
    try {
      await pool.query('SELECT 1');
      return;
    } catch (e) {
      console.log(`[db] waiting for database (${e.code || e.message})...`);
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
  throw new Error('Database is not reachable');
}

export async function migrate() {
  const dir = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'migrations');
  await pool.query(
    'CREATE TABLE IF NOT EXISTS schema_migrations (name TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())',
  );
  const applied = new Set((await pool.query('SELECT name FROM schema_migrations')).rows.map((r) => r.name));
  for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.sql')).sort()) {
    if (applied.has(file)) continue;
    console.log(`[db] applying migration ${file}`);
    await tx(async (c) => {
      await c.query(fs.readFileSync(path.join(dir, file), 'utf8'));
      await c.query('INSERT INTO schema_migrations(name) VALUES ($1)', [file]);
    });
  }
}
