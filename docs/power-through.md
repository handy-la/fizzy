# Power Through

Handy #2304. Una página por tablero (`/boards/:id/power_through`) para
contestar, una tarjeta tras otra, lo que las tarjetas piden a una persona.
Un tablero es un producto: la cola nunca mezcla tableros.

## Qué entra en la cola

La espera estructurada de Dédalo (pregunta pendiente, contestada, vencida,
sustituida) vive en Dédalo, no en Fizzy. Fizzy sólo ve los comentarios de
Dédalo, cerrados con la marca invisible `​⁠⁣`, y la etapa de
la tarjeta. `Card::PendingRequest` recorre los comentarios en orden:

- Pregunta: comentario marcado con ❓ en su texto. Las preguntas sin respuesta
  entre ellas quedan abiertas juntas (la pregunta del agente y el aviso de
  `dedalo work wait` llegan como dos comentarios).
- Un comentario de una persona contesta todas las preguntas abiertas.
- Un comentario marcado que empieza con ⌛ las vence.
- Una pregunta con el mismo id de Dédalo (`q-…-v<n>`) sustituye a la anterior.
- Otro comentario marcado es progreso y no cambia nada (⏳ incluido: una espera
  automática sola nunca crea un pendiente).
- Los comentarios del sistema (movimientos) se ignoran.

Con evidencia insuficiente responde `:review` («Revisar contexto»), nunca una
certeza inventada: un comentario sin marca de la cuenta que pregunta, un aviso
⚠️ de Dédalo justo después de una respuesta (respuesta parcial o rechazada), o
una tarjeta en la etapa AWAITING APPROVAL sin pregunta abierta. Nunca usa
antigüedad, inactividad ni el autor como prueba única.

Las etapas por omisión son las de aprobación (`Column::Approval`) y, si el
tablero no tiene, todas. El orden es la pregunta abierta más antigua y después
el número. La cola lee hasta 200 tarjetas activas de las etapas elegidas.

«De qué trata» es el inicio de la descripción de la tarjeta: no se genera
texto ni se envía la conversación a ningún proveedor.

## Responder

El editor es el del comentario normal: mismo endpoint, sugerencias y
borrador. Ver o saltar no escribe nada. Sólo el botón o Ctrl+Enter publican, y
la página avanza sólo cuando el servidor confirma el comentario.

Cada respuesta lleva un `client_token` hasta que el servidor la resuelve; un
reintento (doble clic, timeout, respuesta perdida) con el mismo token devuelve
el comentario existente (200) en vez de crear otro. El índice único
`comments(card_id, creator_id, client_token)` cierra la carrera.

La confirmación es el estado y una cabecera, nunca el cuerpo: un 201 publicó
exactamente el HTML de esa petición; un 200 de repetición lleva
`Comment-Replay: same` si el comentario guardado es el cuerpo enviado ahora
(comparado con `ActionText::Content#to_html`) o `different` si es una versión
anterior. La página avanza sólo si lo publicado es exactamente el HTML que
tiene el editor; si no, conserva el editor y el borrador y lo dice. Cualquier
otra respuesta correcta (una redirección por sesión vencida) no confirma nada
y conserva el token.

El editor es un elemento permanente de Turbo: conserva los atributos de la
página que lo pintó. Lo que cambia con la página (la URL de avance, la huella)
se lee de `#power_through_state`, que sí se actualiza. Ese estado lleva el id
de la tarjeta enfocada: una confirmación que llega cuando la persona ya pasó a
otra tarjeta conserva lo publicado y no navega. Si la persona volvió a esa
tarjeta, el editor nuevo recibe el aviso `power-through:confirmed`: vacía el
texto que coincide con lo publicado y avisa si tiene otro, para que un segundo
envío con otro token no duplique la respuesta.

Antes de publicar, la página vuelve a leer el veredicto
(`/boards/:id/power_through/cards/:number.json`). Si la huella cambió desde
que se abrió la tarjeta, avisa una vez y conserva el borrador.

## Datos del navegador

- Etapas: `power-through:v1:<cuenta>:<usuario>:<tablero>` en `localStorage`,
  con versión. Etapas borradas se descartan; un valor corrupto se borra.
  Sin sincronización entre dispositivos.
- Borrador: `comment-<usuario>-<tarjeta>`, compartido con la página de la
  tarjeta. La clave anterior `comment-<tarjeta>` se mueve una vez.
- Almacenamiento rechazado: la página y el editor siguen funcionando; sólo no
  se guarda nada.

## Reloj de espera automática (Dédalo #2302, Handy #2306)

Las esperas automáticas (`docs/automatic-waits.md`) son la única fuente
estructurada que Fizzy guarda, y Power Through la lee sin escribirla:

- Una pregunta abierta en los comentarios va primero.
- Sin pregunta abierta, una espera presentable con `human_condition`
  `required` o `pending` hace la tarjeta pendiente («Dédalo declara que esta
  tarjeta necesita a una persona»), con su motivo y su evento.
- Una espera `not_required`, `unknown` o vencida nunca crea un pendiente por
  sí sola.
- La huella incluye la clave y la revisión de cada espera declarada.
