import { google } from 'googleapis';
import db from './db.js';
import { encrypt, decrypt, randomToken } from './crypto.js';

const SCOPES = [
  'https://www.googleapis.com/auth/gmail.readonly',
  'https://www.googleapis.com/auth/gmail.send',
  'openid',
  'email',
  'profile',
];

export function makeOAuthClient() {
  return new google.auth.OAuth2(
    process.env.GOOGLE_CLIENT_ID,
    process.env.GOOGLE_CLIENT_SECRET,
    process.env.GOOGLE_REDIRECT_URI
  );
}

export function getAuthUrl() {
  return makeOAuthClient().generateAuthUrl({
    access_type: 'offline',
    prompt: 'consent',
    scope: SCOPES,
  });
}

export async function handleCallback(code) {
  const oauth = makeOAuthClient();
  const { tokens } = await oauth.getToken(code);
  oauth.setCredentials(tokens);

  const oauth2 = google.oauth2({ version: 'v2', auth: oauth });
  const { data: profile } = await oauth2.userinfo.get();

  const existing = db.prepare('SELECT * FROM users WHERE email = ?').get(profile.email);
  let userId;
  if (existing) {
    // Conservar el refresh_token previo si Google no envía uno nuevo
    const prev = JSON.parse(decrypt(existing.tokens_enc));
    const merged = { ...prev, ...tokens };
    db.prepare('UPDATE users SET tokens_enc = ?, name = ?, picture = ? WHERE id = ?')
      .run(encrypt(JSON.stringify(merged)), profile.name, profile.picture, existing.id);
    userId = existing.id;
  } else {
    const r = db.prepare('INSERT INTO users (email, name, picture, tokens_enc) VALUES (?, ?, ?, ?)')
      .run(profile.email, profile.name, profile.picture, encrypt(JSON.stringify(tokens)));
    userId = r.lastInsertRowid;
  }

  const session = randomToken();
  db.prepare('INSERT INTO sessions (token, user_id) VALUES (?, ?)').run(session, userId);
  return session;
}

export function getUserFromSession(token) {
  if (!token) return null;
  return db.prepare(
    'SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token = ?'
  ).get(token) || null;
}

export function destroySession(token) {
  if (token) db.prepare('DELETE FROM sessions WHERE token = ?').run(token);
}

// Devuelve un cliente OAuth autenticado para el usuario; refresca y persiste tokens si caducan.
export function getAuthedClient(user) {
  const oauth = makeOAuthClient();
  oauth.setCredentials(JSON.parse(decrypt(user.tokens_enc)));
  oauth.on('tokens', (newTokens) => {
    const current = JSON.parse(decrypt(
      db.prepare('SELECT tokens_enc FROM users WHERE id = ?').get(user.id).tokens_enc
    ));
    db.prepare('UPDATE users SET tokens_enc = ? WHERE id = ?')
      .run(encrypt(JSON.stringify({ ...current, ...newTokens })), user.id);
  });
  return oauth;
}

// Middleware Express
export function requireAuth(req, res, next) {
  const user = getUserFromSession(req.cookies?.sinmail_session);
  if (!user) return res.status(401).json({ error: 'No autenticado' });
  req.user = user;
  next();
}
