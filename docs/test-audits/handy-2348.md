# Mapa de trabajo — Handy 2348

Base del fork: `070a8a1d61c5e67a72378c4b9f8691c3b290ea4b`. Contrato:
[`docs/work-map.md`](../work-map.md).

## RED

Excepción explícita: es una vista nueva. En la base no existen la ruta, los
modelos ni el módulo JS; cada prueba nueva falla allí por ausencia (ruta o
constante inexistente), que no es un RED válido. No hay un incidente previo
que reproducir. La sensibilidad de las pruebas de permisos se comprobó durante
la autoría: la primera versión de `WorkMap` registraba un marcador «sin
acceso» aunque descartara la relación, y la prueba «a relation between two
cards the person cannot see is dropped» falló (dos marcadores sobrantes) hasta
corregirlo. Riesgo sin probar: el contrato real de Dédalo, que aún no existe
(Dédalo #2369); las pruebas usan respuestas construidas según el contrato.

## Autoría antes de editar pruebas

Seis archivos nuevos y una prueba agregada a `test/javascript_test.rb`. No se
cambia ni retira ninguna prueba existente.

### `test/models/work_map/snapshot_test.rb`

- **Contrato:** sólo los campos del contrato llegan a Fizzy. Un objeto con una
  clave ajena, un valor fuera de rango, una fecha inválida o una identidad mal
  formada se descarta entero y se cuenta. El sobre con otro esquema se rechaza.
  El texto libre queda en una línea y con límite. Dueño:
  `app/models/work_map/snapshot.rb`.
- **Regresión:** aceptar `claim_token`, `prompt` o un error con ruta; reparar
  un objeto en vez de descartarlo; aceptar un estado de relación «closed»;
  pasar saltos de línea o caracteres de control; ignorar el límite de 5000.
- **Cobertura:** no hay pruebas previas; el modelo es nuevo.
- **Seam:** ninguno. `parse` es la entrada productiva de `WorkMap::Source`.

### `test/models/work_map/source_test.rb`

- **Contrato:** una sola lectura GET autenticada para todos los productos,
  compartida 30 s (un fallo, 10 s); un fallo es un estado con código corto,
  nunca una excepción; sin dirección y token no se pide nada; el archivo de
  ejemplo sólo funciona fuera de producción. Dueño:
  `app/models/work_map/source.rb`; frontera: HTTP (WebMock).
- **Regresión:** pedir una vez por tarjeta o por carga de página; propagar un
  timeout; aceptar más de 2 MiB; enviar la petición sin token; leer el archivo
  de ejemplo en producción.
- **Cobertura:** no hay pruebas previas.
- **Seam:** `cache:` y `file:` son argumentos del constructor. `file:` también
  tiene consumidor productivo (`WORK_MAP_SOURCE_FILE` en desarrollo, para
  mostrar el mapa con datos de ejemplo). `cache:` permite un `MemoryStore`
  porque la caché de pruebas es `:null_store`.

### `test/models/work_map_test.rb`

- **Contrato:** todas las tarjetas abiertas de todos los tableros accesibles
  (Maybe?, columnas, Not Now) en un grafo; productos del registro en tiempo de
  ejecución; relaciones entre productos con su condición; una cerrada sólo si
  explica una cadena; varios bloqueadores con su propia satisfacción; un
  extremo sin acceso sin identidad, uno por relación; relación entre dos
  ocultos descartada; borrador oculto, nunca «ausente»; número inexistente en
  un tablero accesible como «ausente»; ciclos; «sin información de ejecución»
  distinto de fuente fallida, producto fallido, parcial y sin registro;
  inventario acotado. Dueño: `app/models/work_map.rb`.
- **Regresión:** usar `board.cards` (mostraría borradores); mostrar un producto
  sin tablero accesible; llamar «ausente» a una tarjeta de otro tablero;
  cumplir una relación por cierre; ocultar Maybe? o Not Now; tratar un producto
  fallido como «sin dependencias».
- **Cobertura:** no hay pruebas previas. Las de `User#accessible_cards`
  (`test/models/user/accessor_test.rb`) no conocen el mapa.
- **Seam:** `source:` y `max_cards:` son argumentos del constructor; el
  controlador usa sus valores por omisión. `max_cards:` evita crear 3000
  tarjetas para probar el corte.

### `test/controllers/work_maps_controller_test.rb`

- **Contrato:** la respuesta HTML lleva sólo los campos permitidos, filtrados
  por acceso; nada de otro tablero (título, producto, motivo, id) aparece en el
  HTML; el texto libre no cierra el `<script>`; una fuente fallida se declara y
  conserva las tarjetas; el menú enlaza el mapa.
- **Regresión:** serializar un registro o el snapshot completo; olvidar
  `json_escape`; filtrar en el navegador en vez del servidor.
- **Cobertura:** las pruebas de modelo no ven el HTML ni el escape.
- **Seam:** `WORK_MAP_SOURCE_FILE`, el mismo camino del modo de ejemplo.

### `test/javascript/work_map_graph_test.mjs` (vía `test/javascript_test.rb`)

- **Contrato:** cadenas transitivas hacia arriba y abajo (sólo vigentes para
  «destrabaría»); ciclos; filtros y su conteo de relaciones ocultas; marcadores
  visibles con su vecino; búsqueda por producto y número o título sin acentos;
  diseño de izquierda a derecha y aislados por producto; 3000 tarjetas en menos
  de un segundo. Dueño: `app/javascript/helpers/work_map_graph.js`.
- **Regresión:** contar una relación satisfecha como bloqueo; un bucle infinito
  con un ciclo; ocultar una relación con un filtro sin contarla; un diseño
  cuadrático que congela el navegador.
- **Cobertura:** no hay pruebas previas.
- **Seam:** ninguno; el módulo no tiene DOM y la prueba lo carga como el
  navegador.

### `test/system/work_map_test.rb`

- **Contrato:** en el navegador real: todos los productos a la vez con la
  relación cruzada; clic resalta prerrequisitos y dependientes y abre el panel
  con motivo, condición y enlace; teclado (flechas, Enter abre la tarjeta,
  Escape, +, 0) sin disparar los atajos de la página (← va a Home); búsqueda;
  filtros y «Restablecer filtros»; toque en un teléfono; fuente fallida.
- **Regresión:** captura de puntero que pierde el clic; un atajo global que
  navega fuera; un filtro que no vuelve; una búsqueda que no avisa que los
  filtros ocultan la tarjeta.
- **Cobertura:** las pruebas de JS no tocan el DOM ni los eventos.
- **Seam:** ninguno. Usa el driver común (ver `CLAUDE.md`, espera automática).

## Comandos

Ruby 4.0.9 de mise, sin variables de Ruby heredadas, `SAAS=false
BUNDLE_GEMFILE=Gemfile`:

- `bin/rails test test/models/work_map_test.rb test/models/work_map test/controllers/work_maps_controller_test.rb test/system/work_map_test.rb`
- `node --test test/javascript/work_map_graph_test.mjs`
