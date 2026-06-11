// Proveedor Groq — API compatible con el formato OpenAI, vía fetch (sin SDK).
//
// Límites de la capa gratuita de Groq para llama-3.1-8b-instant:
//   - 30 peticiones por minuto
//   - 14.400 peticiones por día
// El throttling y los reintentos ante 429 se gestionan en classifier.js.

const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';

export async function chat({ system, userText, maxTokens = 1024, json = false }) {
  const apiKey = process.env.GROQ_API_KEY;
  if (!apiKey) throw new Error('Falta GROQ_API_KEY en .env');

  const res = await fetch(GROQ_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: process.env.GROQ_MODEL || 'llama-3.1-8b-instant',
      max_tokens: maxTokens,
      temperature: 0.3,
      ...(json ? { response_format: { type: 'json_object' } } : {}),
      messages: [
        { role: 'system', content: system },
        { role: 'user', content: userText },
      ],
    }),
  });

  if (res.status === 429) {
    const retryAfter = Number(res.headers.get('retry-after')) || 5;
    const err = new Error('Rate limit de Groq');
    err.rateLimited = true;
    err.retryAfter = retryAfter;
    throw err;
  }
  if (!res.ok) {
    throw new Error(`Groq HTTP ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }
  const data = await res.json();
  return data.choices[0].message.content;
}
