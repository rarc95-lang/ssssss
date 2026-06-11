import 'dotenv/config';
import express from 'express';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import db from './src/db.js';
import { getAuthUrl, handleCallback, getUserFromSession, destroySession, requireAuth } from './src/auth.js';
import { fetchInbox, sendEmail } from './src/gmail.js';
import { classifyEmail, draftEmail } from './src/classifier.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const app = express();
app.use(express.json({ limit: '1mb' }));

// Parser de cookies mínimo (sin dependencia extra)
app.use((req, _res, next) => {
  req.cookies = Object.fromEntries(
    (req.headers.cookie || '').split(';').filter(Boolean).map((c) => {
      const i = c.indexOf('=');
      return [c.slice(0, i).trim(), decodeURIComponent(c.slice(i + 1))];
    })
  );
  next();
});

app.use(express.static(path.join(__dirname, 'public')));

// ---------- Autenticación ----------
app.get('/api/auth/google', (_req, res) => res.redirect(getAuthUrl()));

app.get('/api/auth/callback/google', async (req, res) => {
  try {
    const session = await handleCallback(req.query.code);
    res.setHeader('Set-Cookie',
      `sinmail_session=${session}; HttpOnly; Path=/; Max-Age=2592000; SameSite=Lax`);
    res.redirect('/');
  } catch (e) {
    console.error('[oauth]', e.message);
    res.status(500).send('Error de autenticación con Google. Revisa la consola del servidor.');
  }
});

app.post('/api/auth/logout', (req, res) => {
  destroySession(req.cookies?.sinmail_session);
  res.setHeader('Set-Cookie', 'sinmail_session=; HttpOnly; Path=/; Max-Age=0');
  res.json({ ok: true });
});

app.get('/api/me', (req, res) => {
  const user = getUserFromSession(req.cookies?.sinmail_session);
  if (!user) return res.json({ user: null });
  res.json({ user: { email: user.email, name: user.name, picture: user.picture } });
});

// ---------- Sincronización y clasificación ----------
// Estado de sincronización por usuario (para la barra de progreso del frontend)
const syncState = new Map();

app.post('/api/sync', requireAuth, async (req, res) => {
  const userId = req.user.id;
  if (syncState.get(userId)?.running) {
    return res.json({ started: false, ...syncState.get(userId) });
  }
  syncState.set(userId, { running: true, total: 0, done: 0, error: null });
  res.json({ started: true });

  try {
    const mensajes = await fetchInbox(req.user, 100);
    const existing = new Set(
      db.prepare('SELECT gmail_id FROM emails WHERE user_id = ?').all(userId).map((r) => r.gmail_id)
    );
    const nuevos = mensajes.filter((m) => !existing.has(m.gmail_id));
    syncState.set(userId, { running: true, total: nuevos.length, done: 0, error: null });

    const insert = db.prepare(`
      INSERT OR IGNORE INTO emails
        (user_id, gmail_id, thread_id, remitente, remitente_email, destinatario,
         asunto, snippet, cuerpo, fecha, categoria, resumen, leido)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);

    for (const m of nuevos) {
      // Los correos ya clasificados nunca se reclasifican (persisten en SQLite).
      const { categoria, resumen } = await classifyEmail(m);
      insert.run(userId, m.gmail_id, m.thread_id, m.remitente, m.remitente_email,
        m.destinatario, m.asunto, m.snippet, m.cuerpo, m.fecha, categoria, resumen, m.leido);
      const st = syncState.get(userId);
      syncState.set(userId, { ...st, done: st.done + 1 });
    }
    syncState.set(userId, { running: false, total: nuevos.length, done: nuevos.length, error: null });
  } catch (e) {
    console.error('[sync]', e);
    syncState.set(userId, { running: false, total: 0, done: 0, error: e.message });
  }
});

app.get('/api/sync/status', requireAuth, (req, res) => {
  res.json(syncState.get(req.user.id) || { running: false, total: 0, done: 0, error: null });
});

// ---------- Bandeja ----------
app.get('/api/emails', requireAuth, (req, res) => {
  const { categoria } = req.query;
  const rows = categoria
    ? db.prepare('SELECT id, remitente, asunto, snippet, resumen, fecha, categoria, leido FROM emails WHERE user_id = ? AND categoria = ? ORDER BY fecha DESC').all(req.user.id, categoria)
    : db.prepare('SELECT id, remitente, asunto, snippet, resumen, fecha, categoria, leido FROM emails WHERE user_id = ? ORDER BY fecha DESC').all(req.user.id);
  res.json({ emails: rows });
});

app.get('/api/emails/counts', requireAuth, (req, res) => {
  const rows = db.prepare(
    'SELECT categoria, COUNT(*) AS total, SUM(CASE WHEN leido = 0 THEN 1 ELSE 0 END) AS no_leidos FROM emails WHERE user_id = ? GROUP BY categoria'
  ).all(req.user.id);
  res.json({ counts: Object.fromEntries(rows.map((r) => [r.categoria, { total: r.total, no_leidos: r.no_leidos }])) });
});

app.get('/api/emails/:id', requireAuth, (req, res) => {
  const email = db.prepare('SELECT * FROM emails WHERE id = ? AND user_id = ?')
    .get(req.params.id, req.user.id);
  if (!email) return res.status(404).json({ error: 'No encontrado' });
  res.json({ email });
});

app.post('/api/emails/:id/leido', requireAuth, (req, res) => {
  db.prepare('UPDATE emails SET leido = ? WHERE id = ? AND user_id = ?')
    .run(req.body.leido ? 1 : 0, req.params.id, req.user.id);
  res.json({ ok: true });
});

app.post('/api/emails/:id/archivar', requireAuth, (req, res) => {
  db.prepare("UPDATE emails SET categoria = 'archivo' WHERE id = ? AND user_id = ?")
    .run(req.params.id, req.user.id);
  res.json({ ok: true });
});

// ---------- IA: borradores ----------
app.post('/api/draft', requireAuth, async (req, res) => {
  try {
    const { instruccion, emailId } = req.body;
    if (!instruccion) return res.status(400).json({ error: 'Falta la instrucción' });
    let original = null;
    if (emailId) {
      original = db.prepare('SELECT * FROM emails WHERE id = ? AND user_id = ?')
        .get(emailId, req.user.id);
    }
    const borrador = await draftEmail({ instruccion, original });
    res.json({ borrador });
  } catch (e) {
    console.error('[draft]', e.message);
    res.status(500).json({ error: 'No se pudo generar el borrador: ' + e.message });
  }
});

// ---------- Envío real ----------
app.post('/api/send', requireAuth, async (req, res) => {
  try {
    const { to, subject, body, emailId } = req.body;
    if (!to || !body) return res.status(400).json({ error: 'Faltan destinatario o cuerpo' });
    let threadId = null, inReplyToMessageId = null;
    if (emailId) {
      const orig = db.prepare('SELECT * FROM emails WHERE id = ? AND user_id = ?')
        .get(emailId, req.user.id);
      if (orig) {
        threadId = orig.thread_id;
        inReplyToMessageId = orig.gmail_id;
        // Al responder, el correo pasa a Archivo (procesado)
        db.prepare("UPDATE emails SET categoria = 'archivo', leido = 1 WHERE id = ?").run(orig.id);
      }
    }
    const result = await sendEmail(req.user, {
      to, subject: subject || '(sin asunto)', body, threadId, inReplyToMessageId,
    });
    res.json({ ok: true, id: result.id });
  } catch (e) {
    console.error('[send]', e.message);
    res.status(500).json({ error: 'No se pudo enviar: ' + e.message });
  }
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`SinMail escuchando en http://localhost:${PORT}`);
  console.log(`Proveedor de IA: ${process.env.AI_PROVIDER || 'groq'}`);
});
