# Evidencia vencida en la espera automática — Handy 2314

Base del fork: `5c389754c3318913ab69b43013a133f23128add6`. Contrato:
[`docs/automatic-waits.md`](../automatic-waits.md), sección «Evidencia
vencida y pendientes humanos». Ficha anterior del mismo contrato:
[`handy-2306.md`](handy-2306.md).

## Autoría antes de editar pruebas

### Pruebas nuevas en `test/models/card/automatic_wait/declaration_test.rb`

Casos: «a report that expired before its first write is stored stale with its
original date» y «a human question on expired evidence prevails, keeps the
expiry, and ending it leaves the follow-up stale».

- **Contrato:** `Card::AutomaticWait::Declaration` acepta un `valid_until`
  pasado y lo guarda sin cambiarlo; la espera queda vencida desde la primera
  escritura. El owner puede cambiar `human_condition` con la misma ejecución y
  la misma fecha: `required` prevalece en `Summary#human`, la fila sigue
  vencida, y al volver a `not_required` el resumen vuelve a `stale`. La
  revisión esperada y la ejecución siguen protegiendo esas escrituras
  (`revision_mismatch`, `run_conflict`). Dueño:
  `app/models/card/automatic_wait/declaration.rb`
  (`validate_time_ranges`); frontera: el modelo, la base de datos y
  `Summary`.
- **Regresión:** volver a rechazar `valid_until ≤ ahora` (el defecto de la
  tarjeta: el productor no puede publicar evidencia vencida ni actualizar el
  pendiente humano sin inventar vigencia); renovar o normalizar la fecha
  enviada; dejar que `not_required` sobre evidencia vencida se lea como sano;
  saltar la comparación de revisión o de ejecución en este camino.
- **Cobertura:** las pruebas de Handy 2306 sólo declaran evidencia vigente;
  «past its validity a wait is an out-of-date follow-up» (`summary_test.rb`)
  vence la espera con `travel`, nunca con una escritura de fecha pasada.
- **Seam:** ninguno nuevo. `travel_to` para el reloj, como en 2306.

### Prueba nueva en `test/controllers/cards/automatic_waits_controller_test.rb`

Caso: «expired evidence is published as stale with its original date».

- **Contrato:** por la API, un `PUT` con `valid_until` pasado contesta 201 y
  publica la fecha original con `freshness: "stale"`; un `pending` declarado
  prevalece en `summary.human`.
- **Regresión:** un 422 `out_of_range` en la frontera HTTP, o una
  serialización que renueve la fecha o marque la fila `current`.
- **Cobertura:** las pruebas de controlador de 2306 sólo publican filas
  vigentes; la frontera JSON de `freshness: "stale"` no tenía prueba.
- **Seam:** ninguno.

### Pruebas cambiadas (contrato modificado a propósito)

- «a retry is recognised after its dates have passed; a new write with those
  dates **is expired evidence**» (antes «…is not»). La primera mitad (el
  reintento es `replayed`) no cambia. La segunda afirmaba 422
  `out_of_range`; ese contrato dejó de existir por decisión de esta tarjeta.
  Ahora afirma `updated`, revisión 2, la fecha original y `stale?`.
- «refuses invalid dates and dates outside the server's horizon»: se retira
  la fila `valid_until 17:59 → out_of_range` porque ese rechazo ya no es el
  contrato. La cubren, con el comportamiento nuevo, las dos pruebas nuevas
  del modelo. Se conservan el límite superior (`+24 h`) y el `next_check_at`
  anterior a `ahora − 60 s` con evidencia vigente, y se agrega el límite
  `next_check_at > valid_until` para evidencia vencida.

## RED y GREEN

- **RED:** `declaration.rb` de `5c389754c3318913ab69b43013a133f23128add6`
  (restaurado en el archivo con `git show HEAD:…`, sin otra edición) con las
  pruebas de este lote. Directorio `fizzy-custom/`, Ruby 4.0.9 de mise primero
  en el `PATH`, sin `GEM_HOME`/`GEM_PATH`, `SAAS=false BUNDLE_GEMFILE=Gemfile`:

  ```bash
  bin/rails test test/models/card/automatic_wait test/controllers/cards/automatic_waits_controller_test.rb
  ```

  Salida 1: 44 casos, 229 aserciones, 4 fallos. Los cuatro son los casos
  nuevos o cambiados, y todos por la causa de la tarjeta:
  `Expected :created/:updated, Actual: :invalid`, y en el controlador
  `Expected 201, was 422` con `valid_until out_of_range`.
- **GREEN:** el mismo comando con la corrección, salida 0: 44 casos, 246
  aserciones, 0 fallos.

## No verificado

- La integración real Dédalo → API → tarjeta (fuera de alcance, como en 2306).
- La prueba de sistema del reloj no cambia: la vista ya muestra «Seguimiento
  desactualizado» por `valid_until`, y el navegador lo recalcula igual.
