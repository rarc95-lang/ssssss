# SinMail

Cliente de correo para iOS, en español, que no muestra mensajes sino **asuntos con estado**.

La unidad no es el correo, es la cosa pendiente real —"cotización camilla"—, que puede
abarcar varios hilos y varias personas. Al llegar correo nuevo no aparece una fila:
cambia el estado de una tarjeta que ya estaba ahí. El hilo queda a un toque, pero no es
la interfaz.

## Los cuatro estados

| Estado | Cuándo |
| --- | --- |
| TUYO | La siguiente acción depende del usuario |
| ESPERANDO | Depende de otra persona |
| LEER | Información sin acción |
| CERRADO | No queda nada pendiente |

Cada asunto tiene `titulo` (≤5 palabras), `estado`, `responsable`, `situacion`
(≤10 palabras), `falta`, `accion` (verbo + objeto, ≤4 palabras), `cita` (frase literal
del hilo) y `confianza` de 0 a 1.

## Reglas que no se rompen

Se piden en el prompt (`Analisis/PromptEspanol.swift`) y se **imponen** en el validador
(`Analisis/ValidadorAsunto.swift`), porque un modelo puede equivocarse y las reglas no:

- El modelo procesa cada hilo y devuelve JSON puro.
- Ante la duda, un hilo es un asunto.
- Nunca CERRADO si hay una pregunta sin responder.
- La cita es literal y jamás parafraseada: si no aparece tal cual en el hilo, se
  sustituye por una frase recortada del propio hilo y baja la confianza.
- Si la confianza es menor que 0.6, el estado es TUYO.
- El cierre lo confirma el usuario y nunca el sistema: un CERRADO propuesto por el
  modelo se guarda como sugerencia y el asunto sigue siendo del usuario.

## Las tres pantallas

- **Bandeja** — tarjetas agrupadas en el orden TUYO, ESPERANDO, LEER, CERRADO;
  encabezado con logo y una línea ("4 asuntos tuyos"); sin contador de no leídos.
- **Borrador** — se abre desde la acción primaria con el texto ya escrito y el cursor
  dentro, sin pantalla intermedia ni spinner. El envío ocurre en un segundo toque.
- **Hilo** — cronología de sólo lectura con la cita resaltada.

La tarjeta lleva chip de estado, título, línea de situación, línea "Falta: …", divisor y
acciones al pie sólo en texto, diferenciadas por color y nunca con fondo. La acción
primaria nombra el acto concreto ("Enviar el número") y jamás dice "Responder". TUYO
muestra tres acciones, ESPERANDO dos, LEER y CERRADO ninguna.

Hay una cuarta vista, **Cuentas**, que es plomería para dar de alta el correo. No forma
parte del producto: se abre desde el encabezado y no vuelve a aparecer.

## Diseño

Página `#FAFAF8`, tarjeta `#FFFFFF`, texto `#1C1C1E`, secundario `#8A8A8E`, hairline
`rgba(0,0,0,.06)`. TUYO `#E7EEFC`/`#1D4ED8`, ESPERANDO `#F7EFE5`/`#96794F`, LEER
`#F0F0ED`/`#71716B`, CERRADO `#E9F1E9`/`#5B7A5B`. SF Pro con título 17/500, situación
15/400, meta 13/400, chip 12/500; sólo pesos 400 y 500, nunca mayúsculas. Tarjeta radio
18, chip radio 8, padding 16/20, separación 12. Sin sombras, iconos, emoji ni avatares.
El cambio de estado se expresa con un fundido de 250 ms y la tarjeta no viaja: reagrupar
es una operación explícita (al abrir o al tirar para actualizar), nunca un efecto
secundario de que llegue un mensaje. "Sin" en `#1D4ED8` y "Mail" en `#1C1C1E`.

Todo vive en `Diseno/Tokens.swift`; lo que no está ahí no debe aparecer en pantalla.

## Por dónde pasa el correo

Por ningún servidor propio, porque no hay ninguno.

- **IMAP y SMTP reales** contra la cuenta del usuario, desde el dispositivo
  (`Correo/`). Cliente IMAP4rev1 con `SELECT`, `UID SEARCH`, `UID FETCH`, `APPEND` e
  `IDLE`; cliente SMTP con STARTTLS o TLS directo, `AUTH PLAIN` y `XOAUTH2`; analizador
  MIME propio con multipart, base64, quoted-printable, juegos de caracteres y palabras
  codificadas de RFC 2047.
- **El transporte usa `CFStream`, no `NWConnection`**, por una razón concreta: SMTP en el
  puerto 587 empieza en claro y sube a TLS sobre la misma conexión, y `NWConnection` no
  sabe hacer eso.
- **CloudKit en la base privada del usuario** (`Sync/`) replica *sólo los asuntos* entre
  sus dispositivos. Los mensajes no salen del dispositivo: la caché de hilos es local.
- **El modelo** se llama directamente desde el dispositivo con la clave del propio
  usuario (`Analisis/MotorClaude.swift`, Messages API de Anthropic sobre HTTP, salida
  ceñida a un esquema JSON). Sin clave configurada, entra un motor heurístico local que
  aplica la regla de oro —un hilo es un asunto— con confianza baja, lo que deja el
  asunto en TUYO.
- **Credenciales en el llavero**, nunca en disco y nunca en CloudKit.

## Prohibido

La IA como asistente, chat o botón. Carpetas, etiquetas o no leídos. Enviar sin que el
usuario vea. Cerrar automáticamente. Inventar la cita.

## Compilar

Requiere Xcode 16 o posterior e iOS 17. Abre `SinMail.xcodeproj` y ejecuta.

Antes de conectar cuentas hay que rellenar la configuración propia, porque el proyecto no
incrusta credenciales de nadie:

1. En `SinMail/Info.plist`, `SinMailGoogleClientID` y `SinMailMicrosoftClientID` con los
   identificadores de cliente OAuth de tu propia app (tipo iOS, sin secreto: se usa
   PKCE). Los esquemas de vuelta ya están registrados: `sinmail-google` y
   `sinmail-microsoft`.
2. En `SinMail/SinMail.entitlements`, el contenedor de iCloud (`iCloud.app.sinmail`) y el
   grupo de llavero, ajustados a tu equipo de desarrollo.
3. La clave del modelo se introduce dentro de la app, en Cuentas, y se guarda en el
   llavero.

iCloud y las cuentas IMAP genéricas usan contraseña de aplicación sobre el puerto 993.
Gmail y Outlook usan OAuth con `XOAUTH2`.
