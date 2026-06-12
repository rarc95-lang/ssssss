import crypto from 'node:crypto';

// Los tokens de Google se cifran con AES-256-GCM antes de guardarse en SQLite.
// La clave se deriva de SESSION_SECRET, así que nunca hay tokens en claro en disco.
function getKey() {
  const secret = process.env.SESSION_SECRET;
  if (!secret) throw new Error('Falta SESSION_SECRET en .env');
  return crypto.createHash('sha256').update(secret).digest();
}

export function encrypt(plain) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', getKey(), iv);
  const enc = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), enc]).toString('base64');
}

export function decrypt(blob) {
  const buf = Buffer.from(blob, 'base64');
  const iv = buf.subarray(0, 12);
  const tag = buf.subarray(12, 28);
  const enc = buf.subarray(28);
  const decipher = crypto.createDecipheriv('aes-256-gcm', getKey(), iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(enc), decipher.final()]).toString('utf8');
}

export function randomToken() {
  return crypto.randomBytes(32).toString('hex');
}
