# Mapa de trabajo: panel tras filtrar, conteo de desbloqueo y plazo total — Handy 2372

Base del fork: `9f42e98c5bc8837faf810738f2f95ce895695595` (Handy #2348 ya en
`main`). Contrato: [`docs/work-map.md`](../work-map.md). Origen: hallazgos no
bloqueantes de las rondas 1 y 2 de Handy #2348.

## Pruebas y sus cuatro respuestas

### 1. «a filter that hides the chosen card empties the panel and disables the chain button»

`test/system/work_map_test.rb`.

- **Contrato:** cuando un filtro oculta la tarjeta elegida, el panel de detalle
  se oculta y «Enfocar cadena» queda deshabilitado. Dueño:
  `work_map_controller.js#draw`. Frontera: el DOM que ve la persona.
- **Regresión:** volver a borrar sólo `this.selected` en `#draw` sin pasar por
  `#select(null)` deja el panel con el detalle anterior y el botón habilitado.
- **Cobertura:** «search by product and number, filters, and reset…» filtra,
  pero sin selección abierta; «the keyboard moves…» limpia con Escape, que ya
  pasaba por `#select(null)`. Ninguna filtra con una tarjeta elegida.
- **Seam:** ninguno; usa la página real.

### 2. «the release count leaves out a dependent that still has another pending prerequisite»

`test/system/work_map_test.rb`, y su detalle puro en
`test/javascript/work_map_graph_test.mjs` («resolving a card releases only the
dependents left with no other pending prerequisite» y «a dependent in a cycle
with another card is not released»).

- **Contrato:** «Resolverla destrabaría N tarjetas» cuenta sólo las tarjetas
  que quedarían sin prerrequisitos vigentes. Dueño: `released` en
  `app/javascript/helpers/work_map_graph.js`, usado por
  `work_map_controller.js#relationLists`.
- **Regresión:** volver a contar con
  `chain(graph, id, "down", { onlyPending: true })` incluye un dependiente con
  otro bloqueador vigente (la prueba de sistema ve 2 en lugar de 1). Las de
  node también fallan si se ignora una relación repetida, una relación
  satisfecha o un ciclo.
- **Cobertura:** la prueba de sistema existente «every product shows at once…»
  sólo cubre una cadena sin bloqueadores extra (2 tarjetas, igual en ambos
  cálculos). La prueba de node «resolving A releases…» cubre `chain`, que se
  conserva para el resaltado.
- **Seam:** `released` es una exportación nueva del helper y su consumidor
  productivo es `work_map_controller.js`.

### 3. «the read gives up when the whole request passes its total deadline»

`test/models/work_map/source_test.rb`.

- **Contrato:** `WorkMap::Source#http_body` termina en `TIMEOUT` aunque la
  respuesta tarde en llegar, y el resultado es `failed/timeout`. Dueño:
  `WorkMap::Source`. Frontera: `Net::HTTP` con WebMock.
- **Regresión:** volver a comprobar el plazo sólo por fragmento del cuerpo hace
  que la lectura espere hasta que llegue la respuesta (1,5 s con plazo 0,2 s).
- **Cobertura:** «a failure is a status…» usa `to_timeout`, que levanta el
  error al instante y no mide el tiempo transcurrido.
- **Seam:** ninguno; `stub_const` baja `TIMEOUT` sólo dentro de la prueba.

### 4. «deliver gives up when the whole request passes its total deadline»

`test/models/webhook/delivery_test.rb`.

- **Contrato:** `Webhook::Delivery#perform_request` termina en
  `2 × ENDPOINT_TIMEOUT` y responde `connection_timeout` (reintentable).
- **Regresión:** igual que la 3, con el chequeo por fragmento de antes.
- **Cobertura:** «deliver when the network timeouts» usa `to_timeout` y no mide
  el tiempo.
- **Seam:** ninguno; `stub_const` sobre `ENDPOINT_TIMEOUT`.

## RED

Comando (Ruby 4.0.9 de mise primero en `PATH`, variables de RVM y Bundler
borradas), en `fizzy-custom/`, con las pruebas nuevas y el código de la base:

```
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 bin/rails test \
  test/system/work_map_test.rb test/models/work_map/source_test.rb test/models/webhook/delivery_test.rb \
  -n "/hides the chosen|release count|total deadline/"
```

Resultado: 4 pruebas, 4 fallos, salida distinta de cero.

- Panel: `expected not to find visible css ".work-map__panel", found 1 match:
  "Cerrar\nBeta #6 …"`.
- Conteo: el panel decía «Resolverla destrabaría 2 tarjetas, directas y
  transitivas: Alpha #3, Alpha #1.»; se esperaba 1 (Alpha #1).
- `WorkMap::Source`: `Expected 1.5022758309496567 to be < 1.0.`
- `Webhook::Delivery`: `Expected 1.6152187740663067 to be < 1.0.`

Excepción RED explícita para las dos pruebas de node: importan `released`, que
no existe en la base; allí fallan por un import ausente, que no es RED válido.
El RED del mismo contrato es el de la prueba de sistema del conteo.

## GREEN

Mismo entorno, con el arreglo:

- `bin/rails test test/system/work_map_test.rb test/models/work_map/source_test.rb
  test/models/webhook/delivery_test.rb test/models/work_map_test.rb
  test/javascript_test.rb test/controllers/work_maps_controller_test.rb`:
  82 pruebas, 0 fallos.
- `node --test test/javascript/work_map_graph_test.mjs`: 10 pruebas, 0 fallos.

## Retiradas

Ninguna prueba ni seam se retira. `chain(…, { onlyPending: true })` se
conserva: su prueba de node sigue vigente.

## Lo que no se verificó

Un servidor real lento en la fase TLS: las pruebas simulan la espera dentro de
WebMock. El `Timeout.timeout` externo cubre todas las fases por igual.
