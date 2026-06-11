# sinmail

Cliente de email minimalista en español que se conecta a tu Gmail real, **clasifica los correos por intención usando IA** y redacta respuestas con IA.

Una sola idea central: clasificación por intención, no por carpetas. Todo correo entrante se asigna automáticamente a una de cinco categorías:

| Categoría | Criterio |
|---|---|
| **Urgente** | Requiere acción hoy: pacientes, plazos inminentes, urgencias de personas cercanas |
| **Por responder** | Espera una respuesta tuya pero no es urgente |
| **Para leer** | Informativo con valor: newsletters de calidad, artículos, actualizaciones relevantes |
| **Boletines** | Marketing, promociones, notificaciones automáticas de bajo valor |
| **Archivo** | Procesado o sin acción pendiente |

Cada correo recibe además un **resumen de una línea en español** generado por IA, visible en la bandeja.

## Stack

- **Backend:** Node.js + Express (sin frameworks pesados)
- **Base de datos:** SQLite local (`data/sinmail.db`, se crea sola — sin setup)
- **Email:** Gmail API oficial (OAuth 2.0, lectura + envío)
- **IA:** Groq por defecto (`llama-3.1-8b-instant`, capa gratuita), con soporte opcional para la API de Anthropic
- **Frontend:** HTML/CSS/JS estático, estética iOS minimalista, mobile-first

## Requisitos

- Node.js 18 o superior
- Una cuenta de Gmail
- Credenciales OAuth de Google Cloud Console (gratis)
- Una API key de Groq (gratis, sin tarjeta)

## 1. Configurar Google Cloud Console (paso a paso)

1. Ve a [console.cloud.google.com](https://console.cloud.google.com) y crea un proyecto nuevo (p. ej. `SinMail`).
2. Menú → **APIs y servicios → Biblioteca** → busca **Gmail API** → **Habilitar**.
3. Menú → **APIs y servicios → Pantalla de consentimiento de OAuth**:
   - Tipo de usuario: **Externo** → Crear.
   - Nombre de la app: `SinMail`. Correo de soporte y de contacto: el tuyo.
   - En **Alcances** no añadas nada, continúa.
   - En **Usuarios de prueba** añade tu dirección de Gmail. Guarda.
4. Menú → **APIs y servicios → Credenciales** → **+ Crear credenciales → ID de cliente de OAuth**:
   - Tipo de aplicación: **Aplicación web**. Nombre: `SinMail Web`.
   - En **URIs de redireccionamiento autorizados** añade exactamente:
     ```
     http://localhost:3000/api/auth/callback/google
     ```
   - **Crear**. Copia el **ID de cliente** y el **Secreto de cliente**.

> La app queda en modo "prueba", lo cual es suficiente: solo tu cuenta (añadida como usuario de prueba) podrá iniciar sesión.

## 2. Obtener la API key de Groq

1. Ve a [console.groq.com](https://console.groq.com) y crea una cuenta (gratis, sin tarjeta).
2. Menú **API Keys** → **Create API Key** → nómbrala `sinmail` → copia la key (empieza por `gsk_`).

**Límites de la capa gratuita de Groq** (`llama-3.1-8b-instant`): 30 peticiones/minuto y 14.400/día. El código serializa las llamadas con un intervalo mínimo de ~2,1 s (≈28 req/min) y reintenta automáticamente ante errores 429 respetando la cabecera `retry-after`, así que clasificar 100 correos tarda unos 3–4 minutos y nunca falla por exceso de velocidad.

## 3. Instalar y correr

```bash
git clone <este-repo>
cd sinmail
npm install

# configuración
cp .env.example .env
# edita .env y rellena:
#   GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, GROQ_API_KEY
# genera el SESSION_SECRET con:
node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"

# arrancar
npm run dev
```

Abre [http://localhost:3000](http://localhost:3000), pulsa **Continuar con Google**, autoriza tu cuenta y listo: tus últimos 100 correos se sincronizan y se clasifican con IA. El botón **⟳** trae correos nuevos sin duplicar ni reclasificar los antiguos.

## Cómo editar el prompt de clasificación

El prompt vive en **`prompts/clasificacion.txt`** (y el de redacción en `prompts/redaccion.txt`). Son archivos de texto plano en español: edítalos con cualquier editor y los cambios se aplican en la siguiente clasificación, **sin reiniciar el servidor**.

Solo afecta a correos nuevos: los ya clasificados persisten en SQLite y nunca se reclasifican.

## Cómo cambiar de proveedor de IA

Edita una sola variable en `.env`:

```bash
# Groq (por defecto, gratis)
AI_PROVIDER=groq

# Anthropic (requiere ANTHROPIC_API_KEY)
AI_PROVIDER=anthropic
```

Reinicia el servidor (`npm run dev`). Los modelos también son configurables: `GROQ_MODEL` y `ANTHROPIC_MODEL`.

## Seguridad

- Todas las keys y tokens viven solo en `.env` (ignorado por git).
- Los tokens de Google se cifran con **AES-256-GCM** (clave derivada de `SESSION_SECRET`) antes de guardarse en SQLite, y **nunca se exponen al frontend** — el navegador solo recibe una cookie de sesión `HttpOnly`.
- Alcances mínimos de Gmail: `gmail.readonly` + `gmail.send` (no puede borrar ni modificar tu correo).

## Estructura

```
server.js              servidor Express + rutas API
src/db.js              esquema SQLite
src/crypto.js          cifrado AES-256-GCM de tokens
src/auth.js            OAuth de Google + sesiones
src/gmail.js           lectura y envío vía Gmail API
src/classifier.js      clasificación + borradores, con throttling
src/ai/index.js        capa de proveedor intercambiable
src/ai/groq.js         proveedor Groq (fetch, formato OpenAI)
src/ai/anthropic.js    proveedor Anthropic (SDK oficial)
prompts/*.txt          prompts editables en español
public/                frontend estático (HTML/CSS/JS)
data/sinmail.db        base de datos local (se crea sola)
```
