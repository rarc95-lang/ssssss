// Capa de proveedor de IA intercambiable.
// Cambia AI_PROVIDER en .env (groq | anthropic) — no hace falta tocar código.
import * as groq from './groq.js';
import * as anthropic from './anthropic.js';

export function getProvider() {
  const name = (process.env.AI_PROVIDER || 'groq').toLowerCase();
  if (name === 'anthropic') return anthropic;
  return groq;
}

export async function chat(opts) {
  return getProvider().chat(opts);
}
