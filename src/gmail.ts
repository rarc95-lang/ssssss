import { google } from 'googleapis';
import { getAuthedClient } from './auth.js';
import type { User, GmailMessage } from './types.js';

function gmailFor(user: User) {
  return google.gmail({ version: 'v1', auth: getAuthedClient(user) });
}

function decodeB64Url(data: string): string {
  return Buffer.from(data.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8');
}

function header(payload: any, name: string): string {
  return payload?.headers?.find((h: any) => h.name.toLowerCase() === name.toLowerCase())?.value ?? '';
}

function extractBody(payload: any): string {
  if (!payload) return '';
  if (payload.mimeType === 'text/plain' && payload.body?.data) {
    return decodeB64Url(payload.body.data);
  }
  if (payload.mimeType === 'text/html' && payload.body?.data) {
    return decodeB64Url(payload.body.data)
      .replace(/<style[\s\S]*?<\/style>/gi, '')
      .replace(/<script[\s\S]*?<\/script>/gi, '')
      .replace(/<[^>]+>/g, ' ')
      .replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<').replace(/&gt;/g, '>')
      .replace(/\s+/g, ' ').trim();
  }
  if (payload.parts) {
    const plain = payload.parts.find((p: any) => p.mimeType === 'text/plain');
    if (plain) return extractBody(plain);
    for (const part of payload.parts) {
      const body = extractBody(part);
      if (body) return body;
    }
  }
  return '';
}

function parseFrom(from: string): { nombre: string; email: string } {
  const m = from.match(/^(.*?)\s*<(.+?)>$/);
  if (m) return { nombre: (m[1] ?? '').replace(/^"|"$/g, '').trim() || (m[2] ?? from), email: m[2] ?? from };
  return { nombre: from, email: from };
}

export async function fetchInbox(user: User, max = 100): Promise<GmailMessage[]> {
  const gmail = gmailFor(user);
  const list = await gmail.users.messages.list({
    userId: 'me',
    labelIds: ['INBOX'],
    maxResults: max,
  });
  const ids = list.data.messages ?? [];
  const out: GmailMessage[] = [];

  for (let i = 0; i < ids.length; i += 10) {
    const batch = await Promise.all(
      ids.slice(i, i + 10).map((m) =>
        gmail.users.messages.get({ userId: 'me', id: m.id!, format: 'full' })
      )
    );
    for (const { data } of batch) {
      const from = parseFrom(header(data.payload, 'From'));
      const labelIds: string[] = data.labelIds ?? [];
      out.push({
        gmail_id: data.id!,
        thread_id: data.threadId ?? data.id!,
        remitente: from.nombre,
        remitente_email: from.email,
        destinatario: header(data.payload, 'To'),
        asunto: header(data.payload, 'Subject'),
        snippet: data.snippet ?? '',
        cuerpo: extractBody(data.payload).slice(0, 8000),
        fecha: new Date(Number(data.internalDate)).toISOString(),
        leido: labelIds.includes('UNREAD') ? 0 : 1,
        message_id: header(data.payload, 'Message-ID'),
        in_reply_to: header(data.payload, 'In-Reply-To'),
      });
    }
  }
  return out;
}

export interface SendOptions {
  to: string;
  subject: string;
  body: string;
  threadId?: string | null;
  inReplyToMessageId?: string | null;
}

export async function sendEmail(user: User, opts: SendOptions) {
  const gmail = gmailFor(user);
  const profile = await gmail.users.getProfile({ userId: 'me' });
  const from = profile.data.emailAddress ?? '';

  const headers = [
    `From: ${from}`,
    `To: ${opts.to}`,
    `Subject: ${opts.subject}`,
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=utf-8',
  ];
  if (opts.inReplyToMessageId) {
    headers.push(`In-Reply-To: ${opts.inReplyToMessageId}`);
    headers.push(`References: ${opts.inReplyToMessageId}`);
  }

  const raw = Buffer.from(headers.join('\r\n') + '\r\n\r\n' + opts.body)
    .toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const result = await gmail.users.messages.send({
    userId: 'me',
    requestBody: {
      raw,
      ...(opts.threadId ? { threadId: opts.threadId } : {}),
    },
  });
  return result.data;
}
