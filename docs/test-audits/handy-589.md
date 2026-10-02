# Handy 589: crear una tarjeta en To work

## Autoría antes de editar las pruebas

- **Contrato:** el pie del borrador ofrece una casilla para To work si el
  tablero tiene esa etapa. Los dos botones publican en la etapa seleccionada;
  crear otra conserva la selección. Sin marcarla, la tarjeta queda en Maybe?.
  El dueño es `Cards::PublishesController` y el pie de creación. La frontera
  es una petición HTTP autenticada, la respuesta HTML y los registros reales.
- **Regresión:** ignorar `column_id` publica en Maybe?; perder el parámetro al
  redirigir desmarca la siguiente tarjeta; buscar la columna fuera del tablero
  acepta una etapa ajena. Las aserciones comprueban esos resultados y el evento
  `triaged`, que usa el flujo normal de traslado y sus webhooks.
- **Cobertura:** se amplían `Cards::PublishesControllerTest` y
  `Cards::DraftsControllerTest`. Los tres casos actuales de publicación sólo
  verifican estado y redirección, sin elegir una etapa. Los casos de borrador
  sólo verifican respuesta y redirección. Se agrega una prueba de sistema para
  comprobar el envío de la casilla por los dos botones reales y la persistencia
  en la siguiente pantalla, riesgo que una petición construida no observa.
- **Seam:** las rutas, el formulario y `triage_into` son entradas productivas.
  No se agrega una API sólo para pruebas ni se reemplaza la base por mocks.

## Evidencia

Base de `fizzy-custom`: `ffbe3e0cae04746fad73ee4fdfad6b90100cb36a`.
Entorno: SQLite, Ruby 3.4.8 de mise, `SAAS=false`.

Se exportó la base con `git archive` a `.context/handy-589-base/` y se copiaron
allí los tres archivos de pruebas de esta entrega. La exportación tiene sus
propias bases SQLite. No se usó otro worktree ni el checkout fuente.

Comando RED exacto, desde `fizzy-custom/`:

```sh
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- ruby -e 'Dir.chdir("../.context/handy-589-base"); exec("./bin/rails", "test", "test/controllers/cards/publishes_controller_test.rb", "test/controllers/cards/drafts_controller_test.rb", "test/system/card_creation_test.rb")'
```

Resultado: salida 1, 11 casos, 64 aserciones, 5 fallos y 1 error. Las tarjetas
quedaron sin columna; la etapa ajena no se rechazó y se creó otro borrador;
el HTML no ofreció la casilla. El error de sistema fue
`Capybara::ElementNotFound: Unable to find checkbox "Create in To work"`.
Las pruebas cargaron y ejecutaron las rutas reales.

GREEN exacto, desde el mismo directorio y con el mismo entorno, sobre el
código corregido:

```sh
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test test/controllers/cards/publishes_controller_test.rb test/controllers/cards/drafts_controller_test.rb test/system/card_creation_test.rb
```

Resultado: salida 0, 11 casos, 89 aserciones, sin fallos ni errores.

| Validación, desde `fizzy-custom/` | Resultado |
| --- | --- |
| `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=4 CI_PROGRESS_BAR=false mise exec -- bin/rails test` | 1.762 casos, 6.830 aserciones, 6 omisiones, salida 0 |
| `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test:system` | 35 casos, 200 aserciones, salida 0 |
| `SAAS=false BUNDLE_GEMFILE=Gemfile mise exec -- bin/rubocop app/controllers/cards/publishes_controller.rb test/controllers/cards/publishes_controller_test.rb test/controllers/cards/drafts_controller_test.rb test/system/card_creation_test.rb` | 4 archivos sin infracciones, salida 0 |
| `git diff --check` | Salida 0 |

Las suites completas usaron seeds 48525 y 62824. La prueba de sistema espera
que desaparezca el título de la tarjeta anterior y confirma la URL del nuevo
borrador antes de usar el segundo botón. Así observa la segunda pantalla.

En Chromium local también se verificaron Ctrl+Shift+Enter y Ctrl+Enter con la
casilla marcada. El tablero terminó con ambas tarjetas en To work. Las capturas
antes/después usan el mismo usuario y tema claro: 1280×900 y 390×844.

## No verificado

No se probó en un teléfono físico, Safari, Firefox ni Hotwire Native. La suite
usa Chromium. El cambio visual corresponde al Fizzy local, con `SAAS=false`;
no se cambió el pie de creación separado del modo SaaS. No se llamó a los
webhooks de Dédalo desde la base de pruebas: se comprobó el evento real
`card_triaged` y su contenido público.
