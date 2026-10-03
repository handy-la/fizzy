# Handy 632: recordar la casilla «Create in To work»

## Autoría antes de editar las pruebas

- **Contrato:** en el pie del borrador, la casilla «Create in To work» toma el
  último estado que la persona eligió en este navegador. Si la marcó, la
  siguiente tarjeta empieza marcada; si la desmarcó, empieza desmarcada. Sin
  elección guardada, la casilla conserva el estado que da el servidor. El
  dueño es el pie de creación (`cards/container/footer/_create.html.erb`) y el
  controlador Stimulus `remembered-checkbox`. La frontera es el navegador real:
  la página, el clic y `localStorage`.
- **Regresión:** quitar el controlador o su acción `change` deja la casilla
  vacía en el borrador siguiente; guardar sólo el estado marcado deja la
  casilla marcada después de desmarcarla. La prueba comprueba los dos casos y
  que la publicación siga en la etapa elegida.
- **Cobertura:** se amplía `test/system/card_creation_test.rb`. Su caso actual
  sólo comprueba que «Create and add another» lleva `column_id` en la URL; no
  abre un borrador nuevo sin ese parámetro. Las pruebas de controlador no
  ejecutan JavaScript y no pueden observar `localStorage`.
- **Seam:** no se agrega ninguno. La prueba usa la ruta, el formulario y el
  almacenamiento reales del navegador.

## Evidencia

Base de `fizzy-custom`: `73f4f7caebfff69cf9f9874267eeb06914f3c32b`.
Entorno: SQLite, Ruby de mise, `SAAS=false`, Chromium de la suite.

Se exportó la base con `git archive` a `.context/handy-632-base/` y se copió
allí `test/system/card_creation_test.rb` de esta entrega. No se usó otro
worktree ni el checkout fuente.

RED exacto, desde `fizzy-custom/`:

```sh
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- ruby -e 'Dir.chdir("../.context/handy-632-base"); exec("./bin/rails", "test", "test/system/card_creation_test.rb")'
```

Resultado: salida 1, 2 casos, 14 aserciones, 1 fallo en la línea 45:
`expected to find visible field "Create in To work" ... that is checked`. La
primera tarjeta sí se publicó en To work; la segunda abrió con la casilla vacía.

GREEN exacto, desde `fizzy-custom/`, sobre el código corregido:

```sh
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test test/system/card_creation_test.rb test/controllers/cards/publishes_controller_test.rb test/controllers/cards/drafts_controller_test.rb
```

Resultado: salida 0, 12 casos, 97 aserciones, sin fallos ni errores.

| Validación, desde `fizzy-custom/` | Resultado |
| --- | --- |
| `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=4 CI_PROGRESS_BAR=false mise exec -- bin/rails test` | 1.762 casos, 6.834 aserciones, 6 omisiones, salida 0 |
| `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test:system` | 40 casos, 226 aserciones, salida 0 (seed 46728) |
| `SAAS=false BUNDLE_GEMFILE=Gemfile mise exec -- bin/rubocop test/system/card_creation_test.rb` | Sin infracciones, salida 0 |
| `git diff --check` | Salida 0 |

## No verificado

No se probó en Safari, Firefox, un teléfono físico ni Hotwire Native. La
preferencia es del navegador, no de la cuenta: otro navegador u otro equipo
empieza sin ella. Si `localStorage` no está disponible, la casilla vuelve al
comportamiento anterior.
