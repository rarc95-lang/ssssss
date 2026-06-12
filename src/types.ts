export interface User {
  id: number;
  email: string;
  name: string | null;
  picture: string | null;
  tokens_enc: string;
  created_at: string;
}

export interface Email {
  id: number;
  user_id: number;
  gmail_id: string;
  thread_id: string | null;
  remitente: string | null;
  remitente_email: string | null;
  destinatario: string | null;
  asunto: string | null;
  snippet: string | null;
  cuerpo: string | null;
  fecha: string | null;
  categoria: Category;
  resumen: string | null;
  leido: number;
  destacado: number;
  trashed: number;
  snoozed_until: string | null;
  message_id: string | null;
  in_reply_to: string | null;
}

export interface EmailRow extends Omit<Email, 'cuerpo'> {
  thread_count?: number;
}

export type Category =
  | 'urgente'
  | 'por_responder'
  | 'para_leer'
  | 'boletines'
  | 'archivo'
  | 'otros';

export const VALID_CATEGORIES: Category[] = [
  'urgente', 'por_responder', 'para_leer', 'boletines', 'archivo', 'otros',
];

export interface Rule {
  id: number;
  user_id: number;
  remitente_email: string;
  categoria: Category;
  created_at: string;
}

export interface Session {
  token: string;
  user_id: number;
  created_at: string;
}

export interface SyncState {
  running: boolean;
  total: number;
  done: number;
  error: string | null;
}

export interface AIClassification {
  categoria: Category;
  resumen: string;
}

export interface GmailMessage {
  gmail_id: string;
  thread_id: string;
  remitente: string;
  remitente_email: string;
  destinatario: string;
  asunto: string;
  snippet: string;
  cuerpo: string;
  fecha: string;
  leido: number;
  message_id: string;
  in_reply_to: string;
}

export interface ChatOptions {
  system: string;
  userText: string;
  maxTokens?: number;
  json?: boolean;
}
