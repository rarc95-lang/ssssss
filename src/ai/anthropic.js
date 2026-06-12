// Proveedor Anthropic — SDK oficial. Se activa con AI_PROVIDER=anthropic en .env.
import Anthropic from '@anthropic-ai/sdk';

let client = null;
function getClient() {
  if (!client) {
    if (!process.env.ANTHROPIC_API_KEY) throw new Error('Falta ANTHROPIC_API_KEY en .env');
    client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });
  }
  return client;
}

export async function chat({ system, userText, maxTokens = 1024 }) {
  const response = await getClient().messages.create({
    model: process.env.ANTHROPIC_MODEL || 'claude-opus-4-8',
    max_tokens: maxTokens,
    system,
    messages: [{ role: 'user', content: userText }],
  });
  const block = response.content.find((b) => b.type === 'text');
  return block ? block.text : '';
}
