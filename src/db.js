import Database from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dataDir = path.join(__dirname, '..', 'data');
fs.mkdirSync(dataDir, { recursive: true });

const db = new Database(path.join(dataDir, 'sinmail.db'));
db.pragma('journal_mode = WAL');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  email TEXT UNIQUE NOT NULL,
  name TEXT,
  picture TEXT,
  tokens_enc TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sessions (
  token TEXT PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id),
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS emails (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id),
  gmail_id TEXT NOT NULL,
  thread_id TEXT,
  remitente TEXT,
  remitente_email TEXT,
  destinatario TEXT,
  asunto TEXT,
  snippet TEXT,
  cuerpo TEXT,
  fecha TEXT,
  categoria TEXT,
  resumen TEXT,
  leido INTEGER DEFAULT 0,
  destacado INTEGER DEFAULT 0,
  UNIQUE(user_id, gmail_id)
);

CREATE TABLE IF NOT EXISTS user_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL REFERENCES users(id),
  remitente_email TEXT NOT NULL,
  categoria TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now')),
  UNIQUE(user_id, remitente_email)
);

CREATE INDEX IF NOT EXISTS idx_emails_user_cat ON emails(user_id, categoria);
CREATE INDEX IF NOT EXISTS idx_emails_user_dest ON emails(user_id, destacado);
`);

// Migraciones seguras para bases de datos existentes
try { db.exec(`ALTER TABLE emails ADD COLUMN destacado INTEGER DEFAULT 0`); } catch {}

export default db;
