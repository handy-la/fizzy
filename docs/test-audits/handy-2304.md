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

## Ronda 2: bloqueantes de la revisión

Revisión 1 sobre `0d517bf97bb5abda2e5c4f0cba8f7b81ff900b0f`: el gate de
Dédalo dio 4 bloqueantes y `bin/signoff` 2 (los mismos dos del gate más dos
propios del gate). Cada corrección tiene su prueba.

Método de RED: en el checkout de la tarjeta, con las pruebas nuevas ya
escritas, se reemplazó sólo el archivo productivo corregido por su versión
de `0d517bf97bb5abda2e5c4f0cba8f7b81ff900b0f` (`git show
0d517bf97bb5abda2e5c4f0cba8f7b81ff900b0f:<archivo> > <archivo>`), se corrió
la prueba y se restauró el archivo. Entorno: `fizzy-custom`, Ruby 4.0.9 de
mise, SQLite, `SAAS=false BUNDLE_GEMFILE=Gemfile`; las de sistema con
`PARALLEL_WORKERS=1`.

- **El refresco cambiaba la tarjeta enfocada al entrar sin `card`.** La página
  redirige a la misma URL con la tarjeta fijada. Archivo:
  `app/controllers/boards/power_throughs_controller.rb`. Comando:
  `bin/rails test test/controllers/boards/power_throughs_controller_test.rb -n "/pins/"`.
  RED: salida 1, «1 tests, 1 failures», `Expected response to be a <3XX:
  redirect>, but was a <200: OK>`. GREEN: salida 0, 0 fallos.
- **Un fallo al leer el veredicto permitía publicar.** `#verified` sólo deja
  enviar si leyó una huella igual a la última que la persona vio; un error
  detiene el envío. Archivo:
  `app/javascript/controllers/power_through_composer_controller.js`.
- **El texto escrito durante el envío se perdía.** Al confirmar, si el editor
  ya no es el texto enviado, queda como borrador y la página no avanza. Mismo
  archivo. Comando de ambas:
  `bin/rails test test/system/power_through_test.rb -n "/cannot be read|on its way/"`.
  RED: salida 1, «2 tests, 2 failures»: no aparece `.power-through__error`
  con «no envié tu respuesta», y no aparece el aviso «sigue aquí, sin
  publicar». GREEN: salida 0 (corrida completa del archivo: «8 tests, 0
  failures», dos veces).
- **La huella no detectaba una pregunta editada.** Incluye un resumen del
  texto de cada pregunta abierta. Archivo: `app/models/card/pending_request.rb`.
  Comando: `bin/rails test test/models/card/pending_request_test.rb -n "/edited/"`.
  RED: salida 1, «1 tests, 1 failures» (`assert_not_equal` con la misma
  huella). GREEN: salida 0.

## Ronda 3: foco en una tarjeta cerrada o pospuesta

Revisión 2 sobre `38cf59edb294ff3b22e1a390ecc39570d039b344`: gate de Dédalo
4→1 y `bin/signoff` 2→2. El defecto común: la tarjeta enfocada que otra
persona cierra o pospone salía también de la búsqueda de `@resolved_card`
(filtro `active`), y el refresco ponía otra tarjeta en su lugar. Ahora la
busca entre todas las tarjetas accesibles del tablero. El segundo bloqueante
de `bin/signoff` era esta misma evidencia sin SHA completo, comandos ni
códigos de salida: se agregó arriba.

- Comando: `bin/rails test test/controllers/boards/power_throughs_controller_test.rb -n "/closed or postponed/"`,
  con `app/controllers/boards/power_throughs_controller.rb` de
  `38cf59edb294ff3b22e1a390ecc39570d039b344`. RED: salida 1, «1 tests, 1
  failures», `Expected at least 1 element matching ".power-through__title",
  found 0`. GREEN (archivo completo): salida 0, «9 tests, 0 failures».
- La prueba cumple las cuatro respuestas de la ficha del controlador: el
  contrato es conservar el foco; la regresión es volver a filtrar por
  `active`; no había cobertura de una tarjeta cerrada o pospuesta; sin seam.

## Ronda 4: el editor conservaba la respuesta publicada

Revisión 3 sobre `db74f6eb4dc0336dada5575b6eab7c22e86d3a6b`:
gate de Dédalo 4→1→1 y `bin/signoff` 2→2→1, el mismo defecto en ambos. En
una etapa de aprobación la tarjeta contestada sigue en la cola para revisión,
así que «Enviar y siguiente» puede volver a la misma tarjeta, y su editor
permanente conservaba el texto publicado listo para enviarse con otro token.
Ahora el editor se vacía antes de navegar cuando su texto es el confirmado;
el texto escrito durante el envío sigue protegido (ronda 2).

- Comando: `PARALLEL_WORKERS=1 bin/rails test test/system/power_through_test.rb -n "/approval stage leaves/"`,
  con `app/javascript/controllers/power_through_composer_controller.js` de
  `db74f6eb4dc0336dada5575b6eab7c22e86d3a6b`. RED: salida 1, «1 tests, 1 failures», `expected not to find
  visible css ".power-through__composer lexxy-editor" with text "Uno.", found
  1 match`. GREEN (archivo completo): salida 0, «9 tests, 0 failures».
- Cuatro respuestas: contrato, un comentario publicado no queda listo para
  publicarse otra vez; regresión, quitar el vaciado; cobertura, ninguna prueba
  volvía a la misma tarjeta; seam, ninguno.

## Ronda 5: reconciliación contra el comentario confirmado

Revisión 4 sobre `1df946afc857b4b323e69cb8b9fc1a4da3cafb44` (ronda concedida
por una persona): gate de Dédalo 4→1→1→2. Los dos bloqueantes nuevos tienen
la misma raíz: el editor permanente guardaba datos de la primera vez que se
pintó. La comparación del reintento usaba el texto del primer intento, no el
del comentario que el servidor confirmó; y la URL de avance seguía siendo la
de las etapas anteriores después de cambiarlas. Rediseño: el envío compara el
`plain_text` del comentario que devuelve el servidor con el texto actual del
editor, y la URL de avance se lee de `#power_through_state`.

- Comando: `PARALLEL_WORKERS=1 bin/rails test test/system/power_through_test.rb -n "/edited text moves on|stages chosen now/"`,
  con `power_through_composer_controller.js`, `_card.html.erb` y
  `_composer.html.erb` de `1df946afc857b4b323e69cb8b9fc1a4da3cafb44`. RED:
  salida 1, «2 tests, 2 failures»: no avanza a la tarjeta #1 tras el
  reintento que confirmó el texto editado, y no llega a la cola vacía de las
  etapas nuevas. GREEN (archivo completo): salida 0, «11 tests, 0 failures».
- Cuatro respuestas: contrato, avanzar sólo con el texto confirmado y con las
  etapas vigentes; regresiones, comparar contra el primer intento o leer la URL
  del editor permanente; cobertura, ninguna prueba editaba entre dos intentos
  perdidos ni cambiaba etapas con un borrador; seam, el mismo reemplazo de
  `window.fetch` de las otras pruebas de red.

### Integración con las esperas automáticas (Handy #2306)

Al rebasar sobre `origin/main` llegó Handy #2306: Fizzy guarda las esperas
automáticas que declara Dédalo, con `human_condition`. Es la fuente única que
pedía la tarjeta, así que `Card::PendingRequest` la lee: una espera
`required` o `pending` sin pregunta abierta es un pendiente; una pregunta
abierta va primero; una espera `not_required` o `unknown` no crea un
pendiente; la huella cambia con la revisión de la espera. Cuatro pruebas
nuevas en `pending_request_test.rb`. Contrato: el de este archivo; regresión:
ignorar la condición declarada o tratar cualquier espera como pendiente;
cobertura: nueva; seam: ninguno, las pruebas declaran por
`Card::AutomaticWait::Declaration`, el escritor productivo. Excepción RED:
la condición declarada no existía en la base anterior de esta tarjeta; las
pruebas fallarían sólo por carga. GREEN: `bin/rails test
test/models/card/pending_request_test.rb`, salida 0, «22 tests, 0 failures».
