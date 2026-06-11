import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';
import { chat } from './ai/index.js';
import db from './db.js';
import { hashContent } from './crypto.js';
import type { AIClassification, Category } from './types.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const promptsDir = path.join(__dirname, '..', 'prompts');

function loadPrompt(name: string): string {
  return fs.readFileSync(path.join(promptsDir, name), 'utf8');
}

// --- Zod schemas para validar salida de la IA ---
const ClassificationSchema = z.object({
  categoria: z.enum(['urgente', 'por_responder', 'para_leer', 'boletines', 'archivo', 'otros']),
  resumen: z.string().min(1).max(200),
});

// --- Caché en memoria (también persiste en SQLite para sobrevivir reinicios) ---
const memCache = new Map<string, AIClassification>();
const CACHE_TTL_MS = 7 * 24 * 60 * 60 * 1000; // 7 días

function getCached(key: string): AIClassification | null {
  if (memCache.has(key)) return memCache.get(key)!;
  const row = db.prepare(
    "SELECT result FROM ai_cache WHERE cache_key = ? AND created_at > datetime('now', '-7 days')"
  ).get(key) as { result: string } | undefined;
  if (!row) return null;
  const parsed = JSON.parse(row.result) as AIClassification;
  memCache.set(key, parsed);
  return parsed;
}

function setCache(key: string, value: AIClassification): void {
  memCache.set(key, value);
  db.prepare('INSERT OR REPLACE INTO ai_cache (cache_key, result) VALUES (?, ?)')
    .run(key, JSON.stringify(value));
}

// --- Circuit breaker: pausa la IA tras 5 fallos consecutivos ---
let failures = 0;
let circuitOpenUntil = 0;
const MAX_FAILURES = 5;
const CIRCUIT_PAUSE_MS = 60_000;

function circuitIsOpen(): boolean {
  if (failures >= MAX_FAILURES && Date.now() < circuitOpenUntil) return true;
  if (Date.now() >= circuitOpenUntil) failures = 0;
  return false;
}

function recordFailure(): void {
  failures++;
  if (failures >= MAX_FAILURES) circuitOpenUntil = Date.now() + CIRCUIT_PAUSE_MS;
}

function recordSuccess(): void {
  failures = 0;
}

// --- Throttling para la capa gratuita de Groq (30 req/min) ---
const MIN_INTERVAL_MS = 2200;
let queue = Promise.resolve();
let lastCall = 0;

function throttled<T>(fn: () => Promise<T>): Promise<T> {
  const run = queue.then(async (): Promise<T> => {
    const usesGroq = (process.env['AI_PROVIDER'] ?? 'groq') === 'groq';
    if (usesGroq) {
      const wait = lastCall + MIN_INTERVAL_MS - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      lastCall = Date.now();
    }
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        const result = await fn();
        recordSuccess();
        return result;
      } catch (e: any) {
        if (e.rateLimited && attempt < 3) {
          await new Promise((r) => setTimeout(r, (e.retryAfter ?? 5) * 1000 + 500));
          lastCall = Date.now();
          continue;
        }
        recordFailure();
        throw e;
      }
    }
    throw new Error('Máximo de reintentos alcanzado');
  });
  queue = run.catch(() => {}) as unknown as Promise<void>;
  return run;
}

const FALLBACK: AIClassification = { categoria: 'otros', resumen: '(sin clasificar)' };

export async function classifyEmail(params: {
  remitente: string;
  remitente_email: string;
  asunto: string;
  cuerpo: string;
  snippet: string;
}): Promise<AIClassification> {
  // Generar clave de caché basada en el contenido (no la fecha ni el ID)
  const contentKey = hashContent(
    [params.remitente_email, params.asunto, (params.cuerpo || params.snippet).slice(0, 500)].join('|')
  );

  const cached = getCached(contentKey);
  if (cached) return cached;

  if (circuitIsOpen()) {
    console.warn('[clasificador] circuit breaker abierto — usando fallback');
    return { categoria: 'otros', resumen: params.asunto || '(sin asunto)' };
  }

  const system = loadPrompt('clasificacion.txt');
  const userText =
    `De: ${params.remitente} <${params.remitente_email}>\n` +
    `Asunto: ${params.asunto}\n\n` +
    `${(params.cuerpo || params.snippet || '').slice(0, 3000)}`;

  try {
    const raw = await throttled(() => chat({ system, userText, maxTokens: 200, json: true }));
    const jsonText = raw.match(/\{[\s\S]*\}/)?.[0] ?? raw;
    const parsed = JSON.parse(jsonText);
    const validated = ClassificationSchema.safeParse(parsed);

    if (!validated.success) {
      console.warn('[clasificador] salida inválida:', validated.error.issues);
      return { categoria: 'otros', resumen: params.asunto || '(sin resumen)' };
    }

    const result: AIClassification = {
      categoria: validated.data.categoria as Category,
      resumen: validated.data.resumen.slice(0, 140),
    };
    setCache(contentKey, result);
    return result;
  } catch (e: any) {
    console.error(`[clasificador] error con "${params.asunto}":`, e.message);
    return { categoria: 'otros', resumen: params.asunto || '(sin resumen)' };
  }
}

export async function draftEmail(params: {
  instruccion: string;
  original?: {
    remitente: string | null;
    remitente_email: string | null;
    asunto: string | null;
    cuerpo: string | null;
    snippet: string | null;
  } | null;
}): Promise<string> {
  const system = loadPrompt('redaccion.txt');
  let userText = `Instrucción del usuario: ${params.instruccion}\n`;
  if (params.original) {
    userText +=
      `\nCorreo original al que se responde:\n` +
      `De: ${params.original.remitente} <${params.original.remitente_email}>\n` +
      `Asunto: ${params.original.asunto}\n\n` +
      `${(params.original.cuerpo || params.original.snippet || '').slice(0, 3000)}`;
  }
  return (await throttled(() => chat({ system, userText, maxTokens: 1024 }))).trim();
}

export async function searchByIntent(params: {
  query: string;
  userId: number;
}): Promise<{ sql_filter: string; explanation: string }> {
  const system = `Eres un asistente que convierte intenciones de búsqueda en filtros SQL para una base de datos de correos.
La tabla se llama "emails" y tiene estas columnas: remitente, remitente_email, asunto, resumen, snippet, fecha, categoria, leido, destacado.
Las categorías son: urgente, por_responder, para_leer, boletines, archivo, otros.
Devuelve SOLO JSON válido con: { "conditions": ["condición SQL sin WHERE", ...], "explanation": "descripción breve en español" }.
Las condiciones deben ser seguras (sin DROP, DELETE, etc). Máximo 3 condiciones AND.
Ejemplo para "correos sin leer": { "conditions": ["leido = 0"], "explanation": "Correos no leídos" }
Ejemplo para "urgentes de esta semana": { "conditions": ["categoria = 'urgente'", "fecha > datetime('now', '-7 days')"], "explanation": "Correos urgentes de los últimos 7 días" }`;

  try {
    const raw = await throttled(() =>
      chat({ system, userText: params.query, maxTokens: 200, json: true })
    );
    const jsonText = raw.match(/\{[\s\S]*\}/)?.[0] ?? raw;
    const parsed = JSON.parse(jsonText);
    const conditions: string[] = Array.isArray(parsed.conditions) ? parsed.conditions : [];
    const safeConds = conditions
      .filter((c: string) => /^[a-z_\s=<>!'"0-9().',-]+$/i.test(c))
      .slice(0, 3);
    return {
      sql_filter: safeConds.length > 0 ? safeConds.join(' AND ') : '1=1',
      explanation: String(parsed.explanation ?? 'Búsqueda personalizada'),
    };
  } catch {
    return { sql_filter: '1=1', explanation: params.query };
  }
}
