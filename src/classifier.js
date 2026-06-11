import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { chat } from './ai/index.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const promptsDir = path.join(__dirname, '..', 'prompts');

// Los prompts se leen del disco en cada uso para que editarlos no requiera reiniciar.
function loadPrompt(name) {
  return fs.readFileSync(path.join(promptsDir, name), 'utf8');
}

const CATEGORIAS = ['urgente', 'por_responder', 'para_leer', 'boletines', 'archivo'];

// --- Throttling para la capa gratuita de Groq (30 req/min) ---
// Serializa las llamadas con un intervalo mínimo de 2,1 s entre peticiones
// (~28 req/min, bajo el límite de 30). Ante un 429 espera retry-after y reintenta.
const MIN_INTERVAL_MS = 2100;
let queue = Promise.resolve();
let lastCall = 0;

function throttled(fn) {
  const run = queue.then(async () => {
    const usesGroq = (process.env.AI_PROVIDER || 'groq') === 'groq';
    if (usesGroq) {
      const wait = lastCall + MIN_INTERVAL_MS - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      lastCall = Date.now();
    }
    for (let attempt = 0; attempt < 4; attempt++) {
      try {
        return await fn();
      } catch (e) {
        if (e.rateLimited && attempt < 3) {
          await new Promise((r) => setTimeout(r, (e.retryAfter || 5) * 1000 + 500));
          lastCall = Date.now();
          continue;
        }
        throw e;
      }
    }
  });
  queue = run.catch(() => {});
  return run;
}

// Clasifica un correo: devuelve { categoria, resumen }
export async function classifyEmail({ remitente, remitente_email, asunto, cuerpo, snippet }) {
  const system = loadPrompt('clasificacion.txt');
  const userText =
    `De: ${remitente} <${remitente_email}>\n` +
    `Asunto: ${asunto}\n\n` +
    `${(cuerpo || snippet || '').slice(0, 3000)}`;

  try {
    const raw = await throttled(() => chat({ system, userText, maxTokens: 200, json: true }));
    const jsonText = raw.match(/\{[\s\S]*\}/)?.[0] || raw;
    const parsed = JSON.parse(jsonText);
    const categoria = CATEGORIAS.includes(parsed.categoria) ? parsed.categoria : 'para_leer';
    const resumen = String(parsed.resumen || '').slice(0, 140) || asunto || '(sin resumen)';
    return { categoria, resumen };
  } catch (e) {
    console.error(`[clasificador] error con "${asunto}":`, e.message);
    return { categoria: 'para_leer', resumen: asunto || '(sin resumen)' };
  }
}

// Genera un borrador de respuesta (o correo nuevo) a partir de una instrucción breve.
export async function draftEmail({ instruccion, original }) {
  const system = loadPrompt('redaccion.txt');
  let userText = `Instrucción del usuario: ${instruccion}\n`;
  if (original) {
    userText +=
      `\nCorreo original al que se responde:\n` +
      `De: ${original.remitente} <${original.remitente_email}>\n` +
      `Asunto: ${original.asunto}\n\n` +
      `${(original.cuerpo || original.snippet || '').slice(0, 3000)}`;
  }
  return (await throttled(() => chat({ system, userText, maxTokens: 1024 }))).trim();
}
