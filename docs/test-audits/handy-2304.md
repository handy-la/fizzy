# Power Through por producto (Handy #2304)

Base del repo dueño: `43baf988f8f8efdc0c19c9d77ccef0002a8b1082` (`origin/main`
de `fizzy-custom`). Diseño y contrato: `docs/power-through.md`.

## Autoría antes de editar pruebas

### `test/models/card/pending_request_test.rb` (nuevo)

- **Contrato:** qué tarjeta espera a una persona según lo que Fizzy ve:
  preguntas marcadas abiertas, respuesta de una persona, vencimiento ⌛,
  sustitución por id `q-…-v<n>`, progreso ignorado, «Revisar contexto» en los
  casos ambiguos y nada en una tarjeta cerrada. Dueño:
  `Card::PendingRequest`. Frontera: comentarios guardados y etapa.
- **Regresión:** tomar el último comentario como pendiente; tratar progreso o
  ⏳ como pendiente; dejar abierta una pregunta contestada, vencida o
  sustituida; contar como respuesta un comentario sin marca de la cuenta que
  pregunta; tomar una cita con la marca dentro de un comentario humano como
  de Dédalo; reabrir una respuesta por un aviso ⚠️ que llega después de otro
  progreso (ese caso apareció al revisar el código propio antes de entregar).
- **Cobertura:** no existía un selector ni pruebas de él.
- **Seam:** ninguno. `Card::PendingRequest.for(card, comments:)` acepta los
  comentarios ya cargados porque `Board::PowerThrough` los precarga; las
  pruebas usan la forma sin argumento.

### `test/models/board/power_through_test.rb` (nuevo)

- **Contrato:** etapas por omisión (aprobación, si no todas), etapas borradas
  descartadas, cola sólo con pendientes o revisión, orden estable, aislamiento
  por tablero, borradores de otra persona fuera, cerradas y pospuestas fuera.
  Dueño: `Board::PowerThrough`.
- **Regresión:** usar `board.cards` en vez de `accessible_cards`; mezclar
  tableros; aceptar una etapa desconocida; ordenar por actividad.
- **Cobertura:** nueva.
- **Seam:** ninguno.

### `test/controllers/boards/power_throughs_controller_test.rb` (nuevo)

- **Contrato:** la página muestra la tarjeta enfocada y su pregunta, no
  escribe nada al leerse, conserva el foco en una tarjeta ya resuelta, dice
  cuando la cola está vacía, responde 404 sin acceso al tablero, y el JSON de
  estado entrega el veredicto y la huella. Dueños: los dos controladores.
- **Regresión:** marcar algo al ver; saltar a otra tarjeta mientras la persona
  escribe; exponer un tablero sin acceso.
- **Cobertura:** nueva.
- **Seam:** ninguno.

### `test/controllers/cards/comments_controller_test.rb` (ampliado)

- **Contrato:** el mismo `client_token` de la misma persona en la misma tarjeta
  es un solo comentario: el reintento responde 200 con el primero (JSON y
  Turbo Stream); el token es por persona; una carrera perdida en el índice
  único responde con el comentario ganador; un token mal formado da 422.
  Dueño: `Cards::CommentsController#create` y `Comment`.
- **Regresión:** quitar la búsqueda previa o el rescate de `RecordNotUnique`
  (el reintento da 500 y el navegador no sabe que el comentario existe);
  limitar el token por tarjeta sin persona.
- **Cobertura:** las pruebas de `create` existentes no envían token.
- **Seam:** la prueba de carrera usa `stubs(:submitted_comment)` para simular
  que la primera lectura no ve la fila que otro proceso insertó; el índice
  único es real. Sin consumidores fuera de la prueba.

### `test/system/power_through_test.rb` (nuevo)

- **Contrato:** recorrido real en el navegador: enviar y avanzar con un solo
  comentario y el borrador borrado; teclas escritas en el editor no navegan y
  fuera sí; respuesta perdida y reintento sin duplicado; solicitud cambiada
  durante la redacción avisa y conserva el borrador; etapas recordadas por
  cuenta, persona y tablero, y valor corrupto ignorado; borrador por persona
  en la página de la tarjeta con migración de la clave anterior.
- **Regresión:** avanzar antes de la confirmación; capturar teclas en el
  editor; un token nuevo en cada intento; perder el borrador; mezclar
  borradores entre personas.
- **Cobertura:** `comment_input_test.rb` y `ai_suggestion_test.rb` cubren el
  editor de la tarjeta, no el envío de esta página ni la clave por persona.
- **Seam:** la prueba de respuesta perdida reemplaza `window.fetch` en la
  página para lanzar después de que el POST llegó: es la frontera de red real
  del navegador. Sin consumidores fuera de la prueba.

### `test/lib/rails_ext/active_record_sql_redaction_test.rb` (ampliado)

- **Contrato:** cada columna con nombre de secreto se redacta en el log SQL o
  se declara no secreta con su razón. `comments.client_token` es una clave
  aleatoria de reintento que sólo encuentra el comentario de quien publica,
  dentro de su sesión: se agrega a `NOT_SECRET`.
- **Regresión:** la prueba existente ya falla si la columna nueva no se
  clasifica (falló en la primera corrida de la suite con esta migración).
- **Cobertura y seam:** sólo una entrada nueva en la lista existente.

## Evidencia RED y GREEN

Entorno: `fizzy-custom`, Ruby 4.0.9 de mise, `SAAS=false
BUNDLE_GEMFILE=Gemfile bin/rails test …`, SQLite.

- **Envío doble.** Con el controlador de la base (sólo se agregó
  `client_token` a los parámetros) y la migración aplicada:
  `bin/rails test test/controllers/cards/comments_controller_test.rb -n "/client token/"`
  salió 1: «4 tests, 2 errors», `ActiveRecord::RecordNotUnique: UNIQUE
  constraint failed: comments.card_id, comments.creator_id,
  comments.client_token` en el reintento y en la carrera. Con el cambio: 4
  tests, 0 fallos.
- **Borrador por persona.** Con `local_save_controller.js` y
  `cards/comments/_new.html.erb` de la base:
  `bin/rails test test/system/power_through_test.rb -n "/per-card draft/"`
  salió 1: `Expected "<p>Borrador anterior</p>" to be nil.` Con el cambio: 0
  fallos.
- **Excepción RED explícita** para el selector, la cola, la página y el resto
  de la prueba de sistema: son funciones nuevas. En la base no existen la
  clase, la ruta ni la vista, así que el único fallo posible es un error de
  carga, que no es RED válido. Contrato aún comprobable: cada prueba nombra su
  regresión arriba. Validación alternativa: recorrido manual en el Fizzy local
  con un tablero de demostración (respuesta, persistencia, salto, contexto,
  etapas, almacenamiento bloqueado y corrupto, respuesta perdida con edición),
  descrito en la tarjeta.

## Lo que no se verificó

- MySQL: la migración y el esquema `db/schema.rb` se escribieron a mano con el
  mismo índice; la suite corrió en SQLite.
- El teclado virtual de un celular real: se comprobó el diseño a 390 px y el
  límite de altura del editor, no un dispositivo.
- La integración con el reloj de Dédalo #2302: todavía no existe en Fizzy.
