# Mapa de trabajo sin Not Now — Handy 2412

Base del fork: `c7e32e4013ff763abfaa40f1b3c0de68ce01fd9a` (`origin/main`).
Contrato: [`docs/work-map.md`](../work-map.md), sección «Qué muestra por
defecto».

## El cambio

Una tarjeta pospuesta (Not Now) es abierta para `Card.open`, y el mapa la
mostraba como una tarjeta más (Dédalo #263 en producción). Ahora:

- `WorkMap#open_cards` excluye `not_now`: la tarjeta no es nodo, no cuenta y
  no ocupa cupo de `MAX_CARDS`.
- La carga de extremos de relaciones no la vuelve a meter como nodo: si una
  relación la nombra, el extremo es un marcador `postponed` con producto y
  número (la persona ve la tarjeta), sin título ni columna. La dependencia
  sigue visible y no parece resuelta.
- Una relación sin tarjeta ni referencia ausente en sus extremos (sólo
  marcadores `inaccessible` o `postponed`) no se envía, igual que antes con
  dos extremos sin acceso.
- Una tarjeta cerrada que es extremo de relación sigue siendo nodo (contexto
  de dependencias): sin cambio.
- La casilla «Not Now» del filtro de estado se retira: ninguna tarjeta del
  mapa la tendría.

No cambia estados, permisos ni datos. La tarjeta pospuesta no se modifica.

## Autoría antes de editar pruebas

### `test/models/work_map_test.rb` — caso cambiado y caso nuevo

- **Contrato:** el inventario del mapa (`WorkMap#nodes`, `#placeholders`,
  `#edges`) no tiene tarjetas pospuestas; una relación que nombra una
  pospuesta la representa con un marcador `postponed` (producto y número) y
  conserva la relación hacia la tarjeta vigente. Dueño:
  `app/models/work_map.rb`.
- **Regresión:** volver a `base_cards.open` sin excluir `not_now`; o cargar el
  extremo de una relación como tarjeta sin mirar si está pospuesta; o
  descartar la relación (la dependencia desaparecería).
- **Cobertura:** el caso «Maybe?, Not Now and a column are told apart, and a
  postponed card stays» afirmaba lo contrario del contrato nuevo: se cambia,
  no se agrega otro. Ningún caso cubría un extremo pospuesto; «a card that
  does not exist … is a missing reference» cubre sólo `missing`.
- **Seam:** ninguno. La prueba entra por `WorkMap.new` y la fuente de archivo
  de ejemplo, el mismo camino de `WorkMapsHelper`.

### `test/controllers/work_maps_controller_test.rb` — caso nuevo

- **Contrato:** la página no recibe el título ni un nodo `card` de la tarjeta
  pospuesta; el marcador lleva exactamente `id`, `kind`, `product`, `number`.
  Dueño: `WorkMapsHelper#work_map_placeholder`.
- **Regresión:** serializar el marcador con la tarjeta entera, o dejar la
  tarjeta como nodo con título.
- **Cobertura:** las pruebas del modelo no ven la serialización; «the browser
  gets only allowed fields» cubre sólo un nodo `card`.
- **Seam:** ninguno.

### `test/system/work_map_test.rb` — caso nuevo

- **Contrato:** en la vista conjunta, con el filtro de un producto, con el de
  otro y después de «Restablecer filtros», la tarjeta pospuesta no aparece y
  el conteo «N tarjetas en el mapa» es el de los nodos `card` dibujados. El
  marcador «Pospuesta (Not Now)» aparece sólo junto a una tarjeta visible.
  Dueños: `work_map_controller.js` y `work_map_graph.js`.
- **Regresión:** que el navegador cuente marcadores como tarjetas, o que un
  filtro o el restablecimiento vuelvan a mostrarla.
- **Cobertura:** «search by product and number, filters, and reset» no tiene
  tarjetas pospuestas. `test/javascript/work_map_graph_test.mjs` cubre
  marcadores en general («a hidden or missing reference shows while a related
  card shows»); no se agrega caso JS porque `visibleIds` trata igual todo
  marcador y no cambia.
- **Seam:** ninguno.

## RED

Ruby 4.0.9 de mise, `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1`,
variables Ruby/Bundler heredadas retiradas y `PATH` con el `bin` de Ruby 4.0.9
primero (sin eso, un subproceso toma `/usr/bin/ruby` 3.4). Directorio
`fizzy-custom/`, pruebas nuevas sobre el código de la base:

- `bin/rails test test/models/work_map_test.rb test/controllers/work_maps_controller_test.rb`:
  3 fallos, todos por la tarjeta pospuesta en el mapa:
  - `Maybe? and a column …`: `Expected [1, 6, 3, 2, 5] to not include 1.`
  - `a postponed card named by a relation …`: `Expected true to be nil or
    false` (hay un nodo para la tarjeta #1).
  - `a postponed card reaches the page only as a postponed reference`: el
    cuerpo incluye `"The logo isn't big enough"`.
- `bin/rails test test/system/work_map_test.rb -n /postponed/`: 1 fallo,
  `expected not to find visible css ".work-map__node[data-node-id='card-1']",
  found 1 match: "Alpha #1\nThe logo isn't big enough\nNot Now · …"`.

## GREEN

- Los cuatro archivos del mapa y `test/javascript_test.rb`: 38 casos,
  0 fallos. `test/system/work_map_test.rb`: 8 casos, 0 fallos (dos corridas).
- Una corrida de `test/system/work_map_test.rb` dio un error en «search by
  product and number, filters, and reset» (línea del buscador, caso sin
  cambios); las dos corridas siguientes pasaron. Se registra como intermitente.
- `bin/rubocop` sobre los archivos Ruby cambiados: sin infracciones.

## Sin verificar

- El resultado real con Dédalo #263: se comprueba en sólo lectura después de
  instalar la entrega autorizada.
