import 'dotenv/config';
import express, { type Request, type Response } from 'express';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import db from './src/db.js';
import {
  getAuthUrl, handleCallback, getUserFromSession,
  destroySession, requireAuth, type AuthRequest,
} from './src/auth.js';
import { fetchInbox, sendEmail } from './src/gmail.js';
import { classifyEmail, draftEmail, searchByIntent } from './src/classifier.js';
import type { Email, EmailRow, SyncState, Category } from './src/types.js';
import { VALID_CATEGORIES } from './src/types.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
app.use(express.json({ limit: '2mb' }));

app.use((req, _res, next) => {
  (req as AuthRequest).cookies = Object.fromEntries(
    (req.headers.cookie ?? '').split(';').filter(Boolean).map((c) => {
      const i = c.indexOf('=');
      return [c.slice(0, i).trim(), decodeURIComponent(c.slice(i + 1))];
    })
  );
  next();
});

app.use(express.static(path.join(__dirname, 'public')));

// ─── Columnas para listado (sin cuerpo) ───────────────────────────────────────
const LIST_COLS = `id, user_id, gmail_id, thread_id, remitente, remitente_email,
  asunto, snippet, resumen, fecha, categoria, leido, destacado, trashed, snoozed_until`;

// ─── Auth ─────────────────────────────────────────────────────────────────────
app.get('/api/auth/google', (_req, res) => res.redirect(getAuthUrl()));

app.get('/api/auth/callback/google', async (req, res) => {
  try {
    const session = await handleCallback(req.query['code'] as string);
    res.setHeader('Set-Cookie',
      `sinmail_session=${session}; HttpOnly; Path=/; Max-Age=2592000; SameSite=Lax`);
    res.redirect('/');
  } catch (e: any) {
    console.error('[oauth]', e.message);
    res.status(500).send('Error de autenticación con Google.');
  }
});

app.post('/api/auth/logout', (req: Request, res: Response) => {
  destroySession((req as AuthRequest).cookies?.['sinmail_session']);
  res.setHeader('Set-Cookie', 'sinmail_session=; HttpOnly; Path=/; Max-Age=0');
  res.json({ ok: true });
});

app.get('/api/me', (req: Request, res: Response) => {
  const user = getUserFromSession((req as AuthRequest).cookies?.['sinmail_session']);
  if (!user) { res.json({ user: null }); return; }
  res.json({ user: { email: user.email, name: user.name, picture: user.picture } });
});

// ─── Sincronización ───────────────────────────────────────────────────────────
const syncState = new Map<number, SyncState>();

app.post('/api/sync', requireAuth, async (req: Request, res: Response) => {
  const user = (req as AuthRequest).user;
  const userId = user.id;
  if (syncState.get(userId)?.running) {
    res.json({ started: false, ...syncState.get(userId) }); return;
  }
  syncState.set(userId, { running: true, total: 0, done: 0, error: null });
  res.json({ started: true });

  try {
    const mensajes = await fetchInbox(user, 100);
    const existing = new Set(
      (db.prepare('SELECT gmail_id FROM emails WHERE user_id = ?').all(userId) as { gmail_id: string }[])
        .map((r) => r.gmail_id)
    );
    const nuevos = mensajes.filter((m) => !existing.has(m.gmail_id));
    syncState.set(userId, { running: true, total: nuevos.length, done: 0, error: null });

    const rulesArr = db.prepare(
      'SELECT remitente_email, categoria FROM user_rules WHERE user_id = ?'
    ).all(userId) as { remitente_email: string; categoria: string }[];
    const rules = new Map(rulesArr.map((r) => [r.remitente_email.toLowerCase(), r.categoria as Category]));

    const insert = db.prepare(`
      INSERT OR IGNORE INTO emails
        (user_id, gmail_id, thread_id, remitente, remitente_email, destinatario,
         asunto, snippet, cuerpo, fecha, categoria, resumen, leido, destacado,
         message_id, in_reply_to)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)`);

    for (const m of nuevos) {
      let categoria: Category, resumen: string;
      const ruleKey = (m.remitente_email ?? '').toLowerCase();
      if (rules.has(ruleKey)) {
        categoria = rules.get(ruleKey)!;
        resumen = m.asunto || '(sin resumen)';
      } else {
        ({ categoria, resumen } = await classifyEmail(m));
      }
      insert.run(
        userId, m.gmail_id, m.thread_id, m.remitente, m.remitente_email,
        m.destinatario, m.asunto, m.snippet, m.cuerpo, m.fecha,
        categoria, resumen, m.leido, m.message_id, m.in_reply_to,
      );
      const st = syncState.get(userId)!;
      syncState.set(userId, { ...st, done: st.done + 1 });
    }
    syncState.set(userId, { running: false, total: nuevos.length, done: nuevos.length, error: null });
  } catch (e: any) {
    console.error('[sync]', e);
    syncState.set(userId, { running: false, total: 0, done: 0, error: e.message });
  }
});

app.get('/api/sync/status', requireAuth, (req: Request, res: Response) => {
  res.json(syncState.get((req as AuthRequest).user.id) ?? { running: false, total: 0, done: 0, error: null });
});

// ─── Despertador de emails dormidos ───────────────────────────────────────────
function wakeupSnoozed(userId: number): void {
  db.prepare(
    "UPDATE emails SET snoozed_until = NULL WHERE user_id = ? AND snoozed_until <= datetime('now')"
  ).run(userId);
}

// ─── Bandeja ──────────────────────────────────────────────────────────────────
app.get('/api/emails', requireAuth, (req: Request, res: Response) => {
  const userId = (req as AuthRequest).user.id;
  wakeupSnoozed(userId);

  const categoria = req.query['categoria'] as string | undefined;
  const limit  = Math.min(+(req.query['limit'] as string)  || 50, 100);
  const offset = +(req.query['offset'] as string) || 0;
  const threads = req.query['threads'] === '1';

  const base = `FROM emails WHERE user_id = ? AND trashed = 0 AND snoozed_until IS NULL`;
  const catFilter = categoria ? ` AND categoria = ?` : '';
  const params = categoria ? [userId, categoria] : [userId];

  if (threads) {
    // Agrupar por thread: devolver solo el email más reciente de cada hilo
    const rows = (db.prepare(`
      WITH latest AS (
        SELECT thread_id, MAX(id) AS max_id
        ${base}${catFilter}
        GROUP BY thread_id
      ),
      counts AS (
        SELECT thread_id, COUNT(*) AS cnt
        FROM emails WHERE user_id = ? AND trashed = 0
        GROUP BY thread_id
      )
      SELECT e.${LIST_COLS.replace(/\n\s+/g, ' ')},
             COALESCE(c.cnt, 1) AS thread_count
      FROM emails e
      JOIN latest l ON e.id = l.max_id
      LEFT JOIN counts c ON e.thread_id = c.thread_id
      ORDER BY e.fecha DESC
      LIMIT ? OFFSET ?`
    ).all(...params, userId, limit, offset) as EmailRow[]);

    const total = (db.prepare(`
      SELECT COUNT(DISTINCT thread_id) AS n
      ${base}${catFilter}`).get(...params) as { n: number }).n;

    res.json({ emails: rows, total }); return;
  }

  const rows = (db.prepare(
    `SELECT ${LIST_COLS} ${base}${catFilter} ORDER BY destacado DESC, fecha DESC LIMIT ? OFFSET ?`
  ).all(...params, limit, offset) as EmailRow[]);

  const total = (db.prepare(`SELECT COUNT(*) n ${base}${catFilter}`).get(...params) as { n: number }).n;
  res.json({ emails: rows, total });
});

app.get('/api/emails/counts', requireAuth, (req: Request, res: Response) => {
  const userId = (req as AuthRequest).user.id;
  const rows = db.prepare(`
    SELECT categoria,
           COUNT(*) AS total,
           SUM(CASE WHEN leido = 0 THEN 1 ELSE 0 END) AS no_leidos
    FROM emails WHERE user_id = ? AND trashed = 0 AND snoozed_until IS NULL
    GROUP BY categoria`).all(userId) as { categoria: string; total: number; no_leidos: number }[];

  const trashCount = (db.prepare(
    'SELECT COUNT(*) n FROM emails WHERE user_id = ? AND trashed = 1'
  ).get(userId) as { n: number }).n;

  res.json({
    counts: Object.fromEntries(rows.map((r) => [r.categoria, { total: r.total, no_leidos: r.no_leidos }])),
    trashCount,
  });
});

// Búsqueda FTS5 (texto libre) o por intención (IA)
app.get('/api/emails/search', requireAuth, async (req: Request, res: Response) => {
  const userId = (req as AuthRequest).user.id;
  const q = (req.query['q'] as string ?? '').trim();
  const intent = req.query['intent'] === '1';

  if (q.length < 2) { res.json({ emails: [], explanation: '' }); return; }

  if (intent) {
    try {
      const { sql_filter, explanation } = await searchByIntent({ query: q, userId });
      const rows = db.prepare(`
        SELECT ${LIST_COLS} FROM emails
        WHERE user_id = ? AND trashed = 0 AND (${sql_filter})
        ORDER BY fecha DESC LIMIT 50`).all(userId) as EmailRow[];
      res.json({ emails: rows, explanation }); return;
    } catch {
      // fallback a FTS
    }
  }

  // FTS5: busca en remitente, email, asunto, resumen, snippet
  const rows = db.prepare(`
    SELECT e.${LIST_COLS.replace(/\n\s+/g, ' ')}
    FROM emails_fts f
    JOIN emails e ON e.id = f.rowid
    WHERE f.emails_fts MATCH ? AND e.user_id = ? AND e.trashed = 0
    ORDER BY rank
    LIMIT 50`).all(q.replace(/['"*]/g, ' ').trim() + '*', userId) as EmailRow[];

  res.json({ emails: rows, explanation: '' });
});

// Papelera
app.get('/api/emails/trashed', requireAuth, (req: Request, res: Response) => {
  const userId = (req as AuthRequest).user.id;
  const rows = db.prepare(
    `SELECT ${LIST_COLS} FROM emails WHERE user_id = ? AND trashed = 1 ORDER BY fecha DESC LIMIT 100`
  ).all(userId) as EmailRow[];
  res.json({ emails: rows });
});

// ─── Hilos ────────────────────────────────────────────────────────────────────
app.get('/api/threads/:threadId', requireAuth, (req: Request, res: Response) => {
  const userId = (req as AuthRequest).user.id;
  const emails = db.prepare(`
    SELECT * FROM emails
    WHERE thread_id = ? AND user_id = ? AND trashed = 0
    ORDER BY fecha ASC`).all(req.params['threadId'], userId) as Email[];
  if (emails.length === 0) { res.status(404).json({ error: 'Hilo no encontrado' }); return; }
  res.json({ emails });
});

// ─── Email individual ─────────────────────────────────────────────────────────
app.get('/api/emails/:id', requireAuth, (req: Request, res: Response) => {
  const email = db.prepare('SELECT * FROM emails WHERE id = ? AND user_id = ?')
    .get(req.params['id'], (req as AuthRequest).user.id) as Email | undefined;
  if (!email) { res.status(404).json({ error: 'No encontrado' }); return; }
  res.json({ email });
});

// Mover a papelera (con posibilidad de deshacer)
app.post('/api/emails/:id/trash', requireAuth, (req: Request, res: Response) => {
  db.prepare('UPDATE emails SET trashed = 1 WHERE id = ? AND user_id = ?')
    .run(req.params['id'], (req as AuthRequest).user.id);
  res.json({ ok: true });
});

// Restaurar de papelera
app.post('/api/emails/:id/restore', requireAuth, (req: Request, res: Response) => {
  db.prepare('UPDATE emails SET trashed = 0 WHERE id = ? AND user_id = ?')
    .run(req.params['id'], (req as AuthRequest).user.id);
  res.json({ ok: true });
});

// Eliminar definitivamente (solo desde papelera)
app.delete('/api/emails/:id', requireAuth, (req: Request, res: Response) => {
  db.prepare('DELETE FROM emails WHERE id = ? AND user_id = ?')
    .run(req.params['id'], (req as AuthRequest).user.id);
  res.json({ ok: true });
});

// Vaciar papelera
app.delete('/api/emails/trashed/all', requireAuth, (req: Request, res: Response) => {
  const info = db.prepare('DELETE FROM emails WHERE user_id = ? AND trashed = 1')
    .run((req as AuthRequest).user.id);
  res.json({ ok: true, deleted: info.changes });
});

app.post('/api/emails/:id/leido', requireAuth, (req: Request, res: Response) => {
  db.prepare('UPDATE emails SET leido = ? WHERE id = ? AND user_id = ?')
    .run(req.body['leido'] ? 1 : 0, req.params['id'], (req as AuthRequest).user.id);
  res.json({ ok: true });
});

app.post('/api/emails/:id/archivar', requireAuth, (req: Request, res: Response) => {
  db.prepare("UPDATE emails SET categoria = 'archivo', trashed = 0 WHERE id = ? AND user_id = ?")
    .run(req.params['id'], (req as AuthRequest).user.id);
  res.json({ ok: true });
});

app.post('/api/emails/:id/destacar', requireAuth, (req: Request, res: Response) => {
  db.prepare('UPDATE emails SET destacado = ? WHERE id = ? AND user_id = ?')
    .run(req.body['destacado'] ? 1 : 0, req.params['id'], (req as AuthRequest).user.id);
  res.json({ ok: true });
});

// Posponer (snooze)
app.post('/api/emails/:id/snooze', requireAuth, (req: Request, res: Response) => {
  const { until } = req.body as { until: string };
  if (!until) { res.status(400).json({ error: 'Falta until' }); return; }
  db.prepare('UPDATE emails SET snoozed_until = ? WHERE id = ? AND user_id = ?')
    .run(new Date(until).toISOString(), req.params['id'], (req as AuthRequest).user.id);
  res.json({ ok: true });
});

app.post('/api/emails/:id/reclasificar', requireAuth, (req: Request, res: Response) => {
  const { categoria } = req.body as { categoria: string };
  if (!VALID_CATEGORIES.includes(categoria as Category)) {
    res.status(400).json({ error: 'Categoría inválida' }); return;
  }
  const email = db.prepare('SELECT remitente_email FROM emails WHERE id = ? AND user_id = ?')
    .get(req.params['id'], (req as AuthRequest).user.id) as { remitente_email: string } | undefined;
  if (!email) { res.status(404).json({ error: 'No encontrado' }); return; }
  db.prepare('UPDATE emails SET categoria = ? WHERE id = ? AND user_id = ?')
    .run(categoria, req.params['id'], (req as AuthRequest).user.id);
  res.json({ ok: true, remitente_email: email.remitente_email });
});

// ─── Reglas ───────────────────────────────────────────────────────────────────
app.get('/api/rules', requireAuth, (req: Request, res: Response) => {
  const rules = db.prepare(
    'SELECT * FROM user_rules WHERE user_id = ? ORDER BY created_at DESC'
  ).all((req as AuthRequest).user.id);
  res.json({ rules });
});

app.post('/api/rules', requireAuth, (req: Request, res: Response) => {
  const { remitente_email, categoria } = req.body as { remitente_email: string; categoria: string };
  if (!remitente_email || !categoria) { res.status(400).json({ error: 'Faltan datos' }); return; }
  db.prepare('INSERT OR REPLACE INTO user_rules (user_id, remitente_email, categoria) VALUES (?, ?, ?)')
    .run((req as AuthRequest).user.id, remitente_email.toLowerCase(), categoria);
  res.json({ ok: true });
});

app.delete('/api/rules/:id', requireAuth, (req: Request, res: Response) => {
  db.prepare('DELETE FROM user_rules WHERE id = ? AND user_id = ?')
    .run(req.params['id'], (req as AuthRequest).user.id);
  res.json({ ok: true });
});

// ─── IA: borradores e intención ───────────────────────────────────────────────
app.post('/api/draft', requireAuth, async (req: Request, res: Response) => {
  try {
    const { instruccion, emailId } = req.body as { instruccion: string; emailId?: number };
    if (!instruccion) { res.status(400).json({ error: 'Falta la instrucción' }); return; }
    const original = emailId
      ? (db.prepare('SELECT * FROM emails WHERE id = ? AND user_id = ?')
          .get(emailId, (req as AuthRequest).user.id) as Email | undefined) ?? null
      : null;
    const borrador = await draftEmail({ instruccion, original });
    res.json({ borrador });
  } catch (e: any) {
    console.error('[draft]', e.message);
    res.status(500).json({ error: 'No se pudo generar el borrador: ' + e.message });
  }
});

// ─── Envío real ───────────────────────────────────────────────────────────────
app.post('/api/send', requireAuth, async (req: Request, res: Response) => {
  try {
    const { to, subject, body, emailId } = req.body as {
      to: string; subject: string; body: string; emailId?: number;
    };
    if (!to || !body) { res.status(400).json({ error: 'Faltan destinatario o cuerpo' }); return; }

    let threadId: string | null = null;
    let inReplyToMessageId: string | null = null;
    if (emailId) {
      const orig = db.prepare('SELECT * FROM emails WHERE id = ? AND user_id = ?')
        .get(emailId, (req as AuthRequest).user.id) as Email | undefined;
      if (orig) {
        threadId = orig.thread_id;
        inReplyToMessageId = orig.message_id ?? orig.gmail_id;
        db.prepare("UPDATE emails SET categoria = 'archivo', leido = 1 WHERE id = ?").run(orig.id);
      }
    }
    const result = await sendEmail((req as AuthRequest).user, {
      to, subject: subject || '(sin asunto)', body, threadId, inReplyToMessageId,
    });
    res.json({ ok: true, id: result.id });
  } catch (e: any) {
    console.error('[send]', e.message);
    res.status(500).json({ error: 'No se pudo enviar: ' + e.message });
  }
});

const PORT = Number(process.env['PORT'] ?? 3000);
app.listen(PORT, () => {
  console.log(`SinMail → http://localhost:${PORT}`);
  console.log(`IA: ${process.env['AI_PROVIDER'] ?? 'groq'}`);
});
