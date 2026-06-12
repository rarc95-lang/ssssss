import Database from 'better-sqlite3';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dataDir = path.join(__dirname, '..', 'data');
fs.mkdirSync(dataDir, { recursive: true });

const db = new Database(path.join(dataDir, 'sinmail.db'));
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  email       TEXT    UNIQUE NOT NULL,
  name        TEXT,
  picture     TEXT,
  tokens_enc  TEXT    NOT NULL,
  created_at  TEXT    DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS sessions (
  token       TEXT    PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at  TEXT    DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS emails (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id        INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  gmail_id       TEXT    NOT NULL,
  thread_id      TEXT,
  remitente      TEXT,
  remitente_email TEXT,
  destinatario   TEXT,
  asunto         TEXT,
  snippet        TEXT,
  cuerpo         TEXT,
  fecha          TEXT,
  categoria      TEXT,
  resumen        TEXT,
  leido          INTEGER DEFAULT 0,
  destacado      INTEGER DEFAULT 0,
  trashed        INTEGER DEFAULT 0,
  snoozed_until  TEXT,
  message_id     TEXT,
  in_reply_to    TEXT,
  UNIQUE(user_id, gmail_id)
);

CREATE TABLE IF NOT EXISTS user_rules (
  id             INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id        INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  remitente_email TEXT   NOT NULL,
  categoria      TEXT    NOT NULL,
  created_at     TEXT    DEFAULT (datetime('now')),
  UNIQUE(user_id, remitente_email)
);

CREATE TABLE IF NOT EXISTS ai_cache (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  cache_key  TEXT UNIQUE NOT NULL,
  result     TEXT NOT NULL,
  created_at TEXT DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_emails_user_cat    ON emails(user_id, categoria, trashed);
CREATE INDEX IF NOT EXISTS idx_emails_user_thread ON emails(user_id, thread_id);
CREATE INDEX IF NOT EXISTS idx_emails_trashed     ON emails(user_id, trashed);
CREATE INDEX IF NOT EXISTS idx_emails_snoozed     ON emails(snoozed_until) WHERE snoozed_until IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_ai_cache_key       ON ai_cache(cache_key);
`);

// Migraciones seguras para bases de datos existentes
for (const col of [
  'ALTER TABLE emails ADD COLUMN destacado      INTEGER DEFAULT 0',
  'ALTER TABLE emails ADD COLUMN trashed        INTEGER DEFAULT 0',
  'ALTER TABLE emails ADD COLUMN snoozed_until  TEXT',
  'ALTER TABLE emails ADD COLUMN message_id     TEXT',
  'ALTER TABLE emails ADD COLUMN in_reply_to    TEXT',
]) {
  try { db.exec(col); } catch { /* ya existe */ }
}

// FTS5 para búsqueda de texto completo
db.exec(`
CREATE VIRTUAL TABLE IF NOT EXISTS emails_fts USING fts5(
  remitente,
  remitente_email,
  asunto,
  resumen,
  snippet,
  content='emails',
  content_rowid='id',
  tokenize='unicode61 remove_diacritics 1'
);

CREATE TRIGGER IF NOT EXISTS emails_fts_insert AFTER INSERT ON emails BEGIN
  INSERT INTO emails_fts(rowid, remitente, remitente_email, asunto, resumen, snippet)
  VALUES (new.id, new.remitente, new.remitente_email, new.asunto, new.resumen, new.snippet);
END;

CREATE TRIGGER IF NOT EXISTS emails_fts_delete AFTER DELETE ON emails BEGIN
  INSERT INTO emails_fts(emails_fts, rowid, remitente, remitente_email, asunto, resumen, snippet)
  VALUES ('delete', old.id, old.remitente, old.remitente_email, old.asunto, old.resumen, old.snippet);
END;

CREATE TRIGGER IF NOT EXISTS emails_fts_update AFTER UPDATE ON emails BEGIN
  INSERT INTO emails_fts(emails_fts, rowid, remitente, remitente_email, asunto, resumen, snippet)
  VALUES ('delete', old.id, old.remitente, old.remitente_email, old.asunto, old.resumen, old.snippet);
  INSERT INTO emails_fts(rowid, remitente, remitente_email, asunto, resumen, snippet)
  VALUES (new.id, new.remitente, new.remitente_email, new.asunto, new.resumen, new.snippet);
END;
`);

export default db;
