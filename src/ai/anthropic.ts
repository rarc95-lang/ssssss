import Anthropic from '@anthropic-ai/sdk';
import type { ChatOptions } from '../types.js';

let client: Anthropic | null = null;

function getClient(): Anthropic {
  if (!client) {
    if (!process.env['ANTHROPIC_API_KEY']) throw new Error('Falta ANTHROPIC_API_KEY en .env');
    client = new Anthropic({ apiKey: process.env['ANTHROPIC_API_KEY'] });
  }
  return client;
}

export async function chat({ system, userText, maxTokens = 1024 }: ChatOptions): Promise<string> {
  const response = await getClient().messages.create({
    model: process.env['ANTHROPIC_MODEL'] ?? 'claude-haiku-4-5-20251001',
    max_tokens: maxTokens,
    system,
    messages: [{ role: 'user', content: userText }],
  });
  const block = response.content.find((b) => b.type === 'text');
  return block?.type === 'text' ? block.text : '';
}
