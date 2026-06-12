import { google } from 'googleapis';
import type { Request, Response, NextFunction } from 'express';
import db from './db.js';
import { encrypt, decrypt, randomToken } from './crypto.js';
import type { User } from './types.js';

const SCOPES = [
  'https://www.googleapis.com/auth/gmail.readonly',
  'https://www.googleapis.com/auth/gmail.send',
  'https://www.googleapis.com/auth/gmail.modify',
  'openid',
  'email',
  'profile',
];

export function makeOAuthClient() {
  return new google.auth.OAuth2(
    process.env['GOOGLE_CLIENT_ID'],
    process.env['GOOGLE_CLIENT_SECRET'],
    process.env['GOOGLE_REDIRECT_URI'],
  );
}

export function getAuthUrl(): string {
  return makeOAuthClient().generateAuthUrl({
    access_type: 'offline',
    prompt: 'consent',
    scope: SCOPES,
  });
}

export async function handleCallback(code: string): Promise<string> {
  const oauth = makeOAuthClient();
  const { tokens } = await oauth.getToken(code);
  oauth.setCredentials(tokens);

  const oauth2 = google.oauth2({ version: 'v2', auth: oauth });
  const { data: profile } = await oauth2.userinfo.get();

  const existing = db.prepare('SELECT * FROM users WHERE email = ?').get(profile.email) as User | undefined;
  let userId: number;

  if (existing) {
    const prev = JSON.parse(decrypt(existing.tokens_enc));
    const merged = { ...prev, ...tokens };
    db.prepare('UPDATE users SET tokens_enc = ?, name = ?, picture = ? WHERE id = ?')
      .run(encrypt(JSON.stringify(merged)), profile.name, profile.picture, existing.id);
    userId = existing.id;
  } else {
    const r = db.prepare('INSERT INTO users (email, name, picture, tokens_enc) VALUES (?, ?, ?, ?)')
      .run(profile.email, profile.name, profile.picture, encrypt(JSON.stringify(tokens)));
    userId = Number(r.lastInsertRowid);
  }

  const session = randomToken();
  db.prepare('INSERT INTO sessions (token, user_id) VALUES (?, ?)').run(session, userId);
  return session;
}

export function getUserFromSession(token: string | undefined): User | null {
  if (!token) return null;
  return (db.prepare(
    'SELECT u.* FROM sessions s JOIN users u ON u.id = s.user_id WHERE s.token = ?'
  ).get(token) as User | undefined) ?? null;
}

export function destroySession(token: string | undefined): void {
  if (token) db.prepare('DELETE FROM sessions WHERE token = ?').run(token);
}

export function getAuthedClient(user: User) {
  const oauth = makeOAuthClient();
  oauth.setCredentials(JSON.parse(decrypt(user.tokens_enc)));
  oauth.on('tokens', (newTokens) => {
    const row = db.prepare('SELECT tokens_enc FROM users WHERE id = ?').get(user.id) as User | undefined;
    if (!row) return;
    const current = JSON.parse(decrypt(row.tokens_enc));
    db.prepare('UPDATE users SET tokens_enc = ? WHERE id = ?')
      .run(encrypt(JSON.stringify({ ...current, ...newTokens })), user.id);
  });
  return oauth;
}

export interface AuthRequest extends Request {
  user: User;
  cookies: Record<string, string>;
}

export function requireAuth(req: Request, res: Response, next: NextFunction): void {
  const cookies = (req as AuthRequest).cookies ?? {};
  const user = getUserFromSession(cookies['sinmail_session']);
  if (!user) { res.status(401).json({ error: 'No autenticado' }); return; }
  (req as AuthRequest).user = user;
  next();
}
