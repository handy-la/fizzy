# Espera automática en tarjetas — Handy 2306

Base del fork: `43baf988f8f8efdc0c19c9d77ccef0002a8b1082`. Contrato:
[`docs/automatic-waits.md`](../automatic-waits.md).

## Autoría antes de editar pruebas

Las cuatro respuestas se escribieron antes de crear las pruebas. Cubren cuatro
archivos nuevos; no se cambia ni retira ninguna prueba existente.

### `test/models/card/automatic_wait/declaration_test.rb`

- **Contrato:** `Card::AutomaticWait::Declaration` es el único escritor. Rechaza
  propiedades ajenas, estados desconocidos, fechas inválidas o fuera del
  horizonte y texto con forma de secreto o comando. Aplica, bajo el bloqueo de
  la tarjeta, época, revisión esperada (comparación atómica), owner y ejecución
  creciente; contesta un reintento idéntico con la fila guardada. Dueño:
  `app/models/card/automatic_wait/declaration.rb`; frontera: el modelo y la
  base de datos.
- **Regresión:** aceptar una escritura con revisión atrasada, una ejecución
  anterior o retirada, una limpieza de otro owner, un relevo de owner sin
  `replaces_owner`, una escritura con la época anterior a un cierre, una
  reapertura o un cambio de tablero; perder la protección al limpiar; contestar
  conflicto a un reintento idéntico; guardar una fecha del cliente sin límite.
- **Cobertura:** no hay pruebas previas: el modelo es nuevo. Las pruebas de
  `Card::Closeable` (`test/models/card/closeable_test.rb`) y de cambio de
  tablero no conocen las esperas.
- **Seam:** ninguno nuevo. `now:` ya es un argumento del productor (el
  controlador no lo pasa; usa el reloj del servidor). Las pruebas usan
  `travel_to` para el reloj.

### `test/models/card/automatic_wait/summary_test.rb`

- **Contrato:** la publicación agregada conserva todos los motivos con orden
  determinista; una condición humana pendiente o requerida prevalece; «no
  requiere intervención humana» sólo con evidencia vigente de todas las esperas;
  la vigencia vencida es «seguimiento desactualizado» y la revisión vencida es
  otra cosa; una espera retirada por la tarjeta conserva su pendiente humano.
  Leer no escribe. Dueño: `summary.rb` y `Card::AutomaticWait#review`.
- **Regresión:** ordenar por inserción, ocultar un motivo, dejar que
  `not_required` gane a `pending`, tratar `unknown` o una espera vencida como
  sana, confundir revisión vencida con vigencia vencida, borrar el pendiente
  humano al cerrar.
- **Cobertura:** ninguna previa.
- **Seam:** `Summary.new(card, now:)`; `now:` lo usa también la vista para que
  el render y su texto usen el mismo instante.

### `test/controllers/cards/automatic_waits_controller_test.rb`

- **Contrato:** la API usa la autenticación existente; cada operación resuelve
  la tarjeta con `accessible_cards` de la cuenta actual; un token de lectura
  lee pero no escribe; el cuerpo es JSON acotado; los códigos HTTP y la forma
  de la respuesta son los publicados en el contrato.
- **Regresión:** una ruta fuera de `CardScoped`, aceptar un token de lectura,
  devolver una tarjeta de otro tablero o cuenta, ignorar en vez de rechazar una
  propiedad ajena, aceptar otro tipo de contenido, cambiar los códigos.
- **Cobertura:** `test/controllers/api_test.rb` prueba los tokens en otros
  recursos; no conoce esta ruta.
- **Seam:** ninguno.

### `test/system/automatic_waits_test.rb`

- **Contrato:** el reloj está encima del contador, también con cero
  comentarios; hover, foco, teclado y toque muestran «Esperando al sistema» y
  todos los motivos; una declaración nueva llega por Cable sin recargar y sin
  duplicar el control; el contador de comentarios sigue igual.
- **Regresión:** volver a esconder el bloque cuando no hay comentarios, perder
  el `z-index` sobre el enlace de la tarjeta (el toque abre la tarjeta), quitar
  el refresco en vivo, duplicar el botón al refrescar.
- **Cobertura:** ninguna prueba de sistema mira el pie de la tarjeta.
- **Seam:** ninguno. El toque se emula con CDP, como en
  `test/system/code_block_copy_test.rb` (Handy 2272).

### Cambio en `test/lib/rails_ext/active_record_sql_redaction_test.rb`

- **Contrato:** toda columna con nombre de secreto está redactada o declarada
  no secreta con un motivo. Se agregan `card_automatic_waits.key` (nombre de
  una espera, ya presente en la URL) y `card_automatic_waits.request_digest`
  (SHA-256 del cuerpo, para reconocer un reintento).
- **Regresión:** una columna nueva con forma de secreto sin clasificar; la
  prueba existente lo detectó en esta tarjeta.
- **Cobertura:** es la prueba dueña de esa lista; no hay otra.
- **Seam:** ninguno.

## RED

**Excepción RED explícita** para las cuatro pruebas nuevas. Es una función
nueva: en la base `43baf988f` no existen la tabla, `Card::AutomaticWait`, la
ruta ni la vista. Ejecutar las pruebas allí falla por `NameError` y por rutas
inexistentes, que la skill `test-audit` no acepta como RED. No hay incidente
previo que reproducir. El contrato sigue comprobable: cada prueba observa la
frontera real (modelo y base, HTTP con token, navegador con Cable).

Validación alternativa: mutaciones controladas, una a la vez, sobre el arreglo,
revertidas después. Cada una debe dejar en rojo la prueba que protege ese
contrato; ver la tabla siguiente.

Comando de cada mutación (en `fizzy-custom/`, Ruby 4.0.9 de mise primero en el
`PATH`, sin variables heredadas de RVM/Bundler):
`SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 bin/rails test <archivo>`.
Script local: `.context/mutate.py`; salida: `.context/mutaciones.log`.

| Mutación | Archivo de prueba | Resultado |
|---|---|---|
| M1 sin comparación de revisión | `declaration_test.rb` | exit 1: 2 fallos (escritor concurrente, escritura atrasada) |
| M2 cerrar no retira las esperas | `declaration_test.rb` | exit 1: 1 fallo (cierre y época) |
| M3 `not_required` gana a otras condiciones | `summary_test.rb` | exit 1: 1 fallo (vigencia vencida) |
| M4 propiedad ajena ignorada | `automatic_waits_controller_test.rb` | exit 1: 1 fallo (422) |
| M5 limpieza que borra la fila | `declaration_test.rb` | exit 1: 1 fallo y 1 error (lápida, idempotencia) |
| M6 reloj sólo con comentarios | `automatic_waits_test.rb` | exit 1: los 6 casos |
| M7 sin `z-index` sobre el enlace | `automatic_waits_test.rb` | exit 1: 4 casos (toque, hover, en vivo, en cero) |
| M8 Enter llega a la lista navegable | `automatic_waits_test.rb` | exit 1: el caso de teclado |

Cada archivo se restauró después de su mutación.

No se demostró una carrera con dos hilos reales: la prueba de carrera usa dos
escritores secuenciales con la misma revisión leída. La defensa es el UPDATE
del cerco antes de leer (bloquea también SQLite) y la comparación de revisión
dentro de ese bloqueo; un caso con hilos en SQLite de prueba no daría más
evidencia que esa secuencia.

## GREEN

Mismo entorno que las mutaciones, base `43baf988f` más este cambio.

- `bin/rails test` (suite sin sistema): 3181 casos; el único fallo fue
  `ActiveRecordSqlRedactionTest` por las dos columnas nuevas, ya clasificadas.
  Después: `test/lib/rails_ext/active_record_sql_redaction_test.rb` 20 casos,
  0 fallos.
- Archivos nuevos: `declaration_test.rb` 17 casos, `summary_test.rb` 10,
  `automatic_waits_controller_test.rb` 11, `automatic_waits_test.rb` 6; 0 fallos.
- `PARALLEL_WORKERS=1 bin/rails test:system --seed 41780`: 117 casos, 0 fallos.

La primera versión de la prueba de sistema declaraba su propio
`driven_by :selenium, using: :headless_chrome`, copiado de
`code_block_copy_test.rb`. En la suite completa ambas clases comparten ese
driver, que `CodeBlockCopyTest#after_teardown` cierra, y Chrome moría a mitad
de la suite (17 errores en otras clases). La prueba usa ahora el driver común.

## Verificación visual

Fizzy real en modo OSS/desarrollo, SQLite de este checkout,
`http://app.fizzy.localhost:3006`, cuenta de semilla 37signals, usuario David.
Antes (base, sin cambios) y después, en 1280×900 y 390×844, tema claro. La
actualización en vivo se probó con la API real: un `PUT` con token de escritura
local agregó un tercer motivo a una tarjeta con cero comentarios; la página no
se recargó (marca en `window`) y siguió con un botón por tarjeta.

## Ronda 1 de revisión: dos bloqueantes

Los dos gates (Dédalo y `bin/signoff`) dieron FAIL en la ronda 1 con los
mismos dos bloqueantes sobre `233b93c5c`:

1. Una espera retirada por la tarjeta con pendiente humano no se podía limpiar
   (`already_retired`). Corrección: la limpieza sólo rechaza una espera ya
   limpiada por su owner; una retirada por la tarjeta se limpia, también con
   la tarjeta cerrada.
2. Los límites de fecha contra el reloj se comprobaban antes de reconocer un
   reintento, y un reintento tardío recibía 422. Corrección: el formato se
   valida sin bloqueo; los límites, bajo el bloqueo y después del reintento.

Autoría (amplía `declaration_test.rb`, mismo contrato y mismas cuatro
respuestas de arriba): dos casos nuevos, «a retry is recognised after its
dates have passed…» y «the owner clears a pending human decision that closing
kept on the card…». Regresión que detectan: los dos defectos citados.

- **RED:** `declaration.rb` del commit revisado en la ronda 1,
  `233b93c5c642149f7260b9b8832535a4fd1bc140` (sin la corrección), con la prueba nueva:
  `bin/rails test test/models/card/automatic_wait/declaration_test.rb -n "/retry is recognised after|clears a pending human decision/"`,
  salida 1; 2 casos, 2 fallos por aserción (`Expected: :replayed, Actual:
  :invalid`; `Expected: :cleared, Actual: :conflict`). Log local:
  `.context/handy-2306-red-r1.log`.
- **GREEN:** el mismo comando con la corrección, salida 0; 2 casos, 15
  aserciones. Log local: `.context/handy-2306-green-r1.log`. Archivos del
  contrato: 40 casos, 0 fallos.

## Ronda 2 de revisión: un bloqueante por gate

Sobre `2e2215dc999de42afc20b0da17db256e64036bb2`, cada gate dio FAIL con un
bloqueante (2→1 en los dos):

1. Gate de Dédalo: volver a declarar una clave limpia no contaba contra el
   límite de 20 esperas activas. Corrección: `refuse_reactivation` aplica el
   límite cuando una lápida vuelve a estar activa.
2. `bin/signoff`: la evidencia RED de la ronda 1 no daba el SHA completo.
   Corregido arriba.

Autoría (amplía `declaration_test.rb`, mismo contrato): el caso «declaring a
cleared key again counts against the active limit». Regresión: reactivar una
lápida con 20 esperas activas deja 21.

- **RED:** `declaration.rb` de `2e2215dc999de42afc20b0da17db256e64036bb2` con
  la prueba nueva:
  `bin/rails test test/models/card/automatic_wait/declaration_test.rb -n "/counts against the active limit/"`,
  salida 1; 1 caso, 1 fallo por aserción (`Expected: :too_many_waits, Actual:
  :updated`). Log local: `.context/handy-2306-red-r2.log`.
- **GREEN:** el mismo comando con la corrección, salida 0. Log local:
  `.context/handy-2306-green-r2.log`.
