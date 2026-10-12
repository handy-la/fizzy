# Handy 939: autorización de búsqueda HTML

## Autoría antes de editar las pruebas

- **Contrato:** `GET /search` HTML sólo muestra resultados cuya tarjeta pertenece
  a `Current.user.accessible_cards` en el momento de consultar. El comentario
  se autoriza por su `card_id`. El usuario del destino conserva el resultado,
  aunque el índice aún indique el tablero anterior. Dueño: `User::Searcher`;
  frontera observada: respuesta HTML de `SearchesController`.
- **Regresión:** confiar en el `board_id` del documento permite al miembro del
  origen leer el comentario, el título actual y el nombre del destino. Se prueba
  con la actualización del índice pendiente, fallida y retirada de la cola.
  Otro caso coloca 16 comentarios inaccesibles antes de un resultado permitido:
  deben quedar fuera antes de calcular la página y el enlace siguiente.
- **Cobertura:** `SearchesControllerTest#search` comprueba acceso estático.
  `Card::BoardMoveSearchTest` ejecuta los jobs antes de buscar. Ninguno cubre el
  intervalo con el índice atrasado. Se amplía la prueba del controlador porque
  observa tanto datos filtrados como título, tablero y paginación entregados.
- **Seam:** se usa la petición real, el índice real y `Card#move_to`.
  No se añade API de pruebas. Sólo el caso de fallo sustituye
  `Card#reindex_comments` para provocar una excepción del job; no sustituye la
  búsqueda ni la autorización. El caso retirado vacía la cola de pruebas.

## Evidencia

Base sin corrección: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.
La versión candidata de `test/controllers/searches_controller_test.rb` tiene
SHA-256 `850e6a0a53dbc36295c38f386901b1dcf09cb2a5b524b3ab4af13e51bc68586c`.
Se exportó la base con `git archive` a `.context/handy-939-base` y se copió sólo
esa prueba. No se usó el source checkout ni otro worktree.

Entorno: Ruby 3.4.8 de mise, SQLite, OSS. Desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH \
  -u BUNDLE_GEMFILE SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 \
  CI_PROGRESS_BAR=false mise exec -- ruby -e \
  'Dir.chdir("../.context/handy-939-base"); exec("./bin/rails", "test", "test/controllers/searches_controller_test.rb")'
```

**RED:** código de salida 1; 16 pruebas, 134 aserciones, 4 fallos y 0 errores.
Los casos pendiente, fallido y descartado esperaban cero resultados y recibían
uno. El caso de paginación recibía el título privado en la primera página en
lugar del resultado permitido. Los fallos son de acceso, no de preparación.

Sobre el arreglo se usó el mismo runner y archivo, con `PARALLEL_WORKERS=1`:

```bash
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH \
  -u BUNDLE_GEMFILE SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 \
  CI_PROGRESS_BAR=false mise exec -- bin/rails test test/controllers/searches_controller_test.rb
```

**GREEN:** código de salida 0; 16 pruebas, 192 aserciones, 0 fallos y 0 errores.
Se comprueba que el miembro del destino ve el comentario y que el miembro del
origen no recibe comentario, título ni nombre del destino.

La corrección queda en `User#search`, utilizado por HTML. `search_relation`
conserva su filtro anterior y sus consumidores siguen autorizando mediante
la relación de tarjetas. La primera ejecución completa mostró un cambio en
`Card::SearchableTest#card search` al cambiar también `search_relation`; se
redujo el alcance antes de entregar.

**Suite completa:** el mismo entorno con `PARALLEL_WORKERS=4` y
`mise exec -- bin/rails test`: código de salida 0; 1869 pruebas, 7468 aserciones,
0 fallos, 0 errores y 6 omisiones. Las omisiones pertenecen a las pruebas
existentes. `bin/rubocop app/models/user/searcher.rb
test/controllers/searches_controller_test.rb`: 2 archivos sin infracciones.

## Lo que no se comprobó

No se ejecutó esta regresión con MySQL ni en modo SaaS. No se hicieron pruebas
de navegador: la reproducción utiliza peticiones HTML reales en integración.
No se modifican marcado, estilos ni textos de pantalla.
