import { google } from 'googleapis';
import { getAuthedClient } from './auth.js';

function gmailFor(user) {
  return google.gmail({ version: 'v1', auth: getAuthedClient(user) });
}

function decodeB64Url(data) {
  return Buffer.from(data.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
}

function header(payload, name) {
  return payload.headers?.find((h) => h.name.toLowerCase() === name.toLowerCase())?.value || '';
}

// Extrae el cuerpo en texto plano (con fallback a HTML sin etiquetas)
function extractBody(payload) {
  if (!payload) return '';
  if (payload.mimeType === 'text/plain' && payload.body?.data) {
    return decodeB64Url(payload.body.data);
  }
  if (payload.mimeType === 'text/html' && payload.body?.data) {
    return decodeB64Url(payload.body.data)
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ')
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/\s+/g, ' ')
      .trim();
  }
  if (payload.parts) {
    // Preferir text/plain entre las partes
    const plain = payload.parts.find((p) => p.mimeType === 'text/plain');
    if (plain) return extractBody(plain);
    for (const part of payload.parts) {
      const body = extractBody(part);
      if (body) return body;
    }
  }
  return '';
}

function parseFrom(from) {
  const m = from.match(/^(.*?)\s*<(.+?)>$/);
  if (m) return { nombre: m[1].replace(/^"|"$/g, '').trim() || m[2], email: m[2] };
  return { nombre: from, email: from };
}

// Trae los metadatos + cuerpo de los últimos `max` correos de la bandeja de entrada.
export async function fetchInbox(user, max = 100) {
  const gmail = gmailFor(user);
  const list = await gmail.users.messages.list({
    userId: 'me',
    labelIds: ['INBOX'],
    maxResults: max,
  });
  const ids = list.data.messages || [];
  const out = [];
  // Lotes de 10 peticiones en paralelo para no saturar la API de Gmail
  for (let i = 0; i < ids.length; i += 10) {
    const batch = await Promise.all(
      ids.slice(i, i + 10).map((m) =>
        gmail.users.messages.get({ userId: 'me', id: m.id, format: 'full' })
      )
    );
    for (const { data } of batch) {
      const from = parseFrom(header(data.payload, 'From'));
      out.push({
        gmail_id: data.id,
        thread_id: data.threadId,
        remitente: from.nombre,
        remitente_email: from.email,
        destinatario: header(data.payload, 'To'),
        asunto: header(data.payload, 'Subject'),
        snippet: data.snippet || '',
        cuerpo: extractBody(data.payload).slice(0, 8000),
        fecha: new Date(Number(data.internalDate)).toISOString(),
        leido: data.labelIds?.includes('UNREAD') ? 0 : 1,
      });
    }
  }
  return out;
}

// Envía un correo real por Gmail. Si threadId/inReplyTo están presentes, responde en el hilo.
export async function sendEmail(user, { to, subject, body, threadId, inReplyToMessageId }) {
  const gmail = gmailFor(user);

  let references = '';
  if (inReplyToMessageId) {
    const orig = await gmail.users.messages.get({
      userId: 'me', id: inReplyToMessageId, format: 'metadata',
      metadataHeaders: ['Message-ID'],
    });
    const msgId = orig.data.payload.headers?.find(
      (h) => h.name.toLowerCase() === 'message-id'
    )?.value;
    if (msgId) references = `In-Reply-To: ${msgId}\r\nReferences: ${msgId}\r\n`;
  }

  const encodedSubject = `=?UTF-8?B?${Buffer.from(subject, 'utf8').toString('base64')}?=`;
  const raw = Buffer.from(
    `To: ${to}\r\n` +
    `Subject: ${encodedSubject}\r\n` +
    references +
    `Content-Type: text/plain; charset=UTF-8\r\n` +
    `Content-Transfer-Encoding: base64\r\n\r\n` +
    Buffer.from(body, 'utf8').toString('base64'),
    'utf8'
  ).toString('base64url');

  const res = await gmail.users.messages.send({
    userId: 'me',
    requestBody: { raw, ...(threadId ? { threadId } : {}) },
  });
  return res.data;
}
