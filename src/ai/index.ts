import type { ChatOptions } from '../types.js';
import * as groq from './groq.js';
import * as anthropic from './anthropic.js';

export function getProvider() {
  const name = (process.env['AI_PROVIDER'] ?? 'groq').toLowerCase();
  if (name === 'anthropic') return anthropic;
  return groq;
}

export async function chat(opts: ChatOptions): Promise<string> {
  return getProvider().chat(opts);
}
