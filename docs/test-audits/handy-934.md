# Admisión y turnos de sugerencias

## Autoría antes de editar pruebas

Base: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.

- **Contrato:** el POST rechaza con 429 el trabajo que excede un usuario en
  espera o ejecución, dos solicitudes activas por cuenta y cuatro globales.
  Reserva como máximo diez llamadas por cuenta y treinta globales por hora.
  El worker da turnos por cuenta y conserva los plazos con llamadas de 90 s.
  Dueños: `Card::SuggestionRequest`, su controlador y `Card::SuggestionJob`.
  Fronteras: HTTP, filas persistidas, cola real de Active Job y proveedor HTTP.
- **Regresión:** admitir cada tarjeta sin contar el usuario acumula trabajo;
  contar sólo pendientes omite el proveedor ocupado; reiniciar un título en
  curso elude la reserva; usar FIFO deja que una cuenta repita antes de otra;
  contar filas mutables pierde gasto al reintentar la misma tarjeta.
- **Cobertura:** `suggestions_controller_test.rb` cubre reutilización, vencimiento
  y fallos externos, pero no admisión entre tarjetas, cuentas ni presupuesto.
  Se amplía ese archivo. Los nuevos casos de modelo observan límites globales,
  turnos y recuperación por el barrido; no duplican controles de autorización.
  El caso de título sustituido conserva la protección del token antiguo, pero
  exige 429 mientras su trabajo está activo. La prueba de admisión concurrente
  usa dos conexiones reales y dos tarjetas; observa un aceptado, un rechazado,
  una fila activa, una reserva y un solo job. El caso de inicialización del
  planificador protege solicitudes admitidas antes de existir su fila global;
  es preventivo y pasa también en la base.
- **Seam:** se usan POST, `request`, el job real, el barrido existente, WebMock y
  el reloj de pruebas. No se agrega una API destinada sólo a pruebas.
  Los nuevos datos de presupuesto y bloqueo sirven a procesos web y workers.

## Evidencia RED y GREEN

Se exportó la base con `git archive` a `.context/handy-934-base` y se copiaron
los tres candidatos indicados. Cada exportación usa su SQLite propio. No se
usó el source checkout ni otro worktree. Ruby: mise 3.4.8.

SHA-256 de los candidatos idénticos en RED y GREEN:

| Archivo bajo `test/` | SHA-256 |
|---|---|
| `controllers/cards/suggestions_controller_test.rb` | `0153099c126b118366c72d8f7e834aec639f71b2a30869f25c5483ecacd552fb` |
| `models/card/suggestion_queue_test.rb` | `cd836faf2796e19f883dff21d037289e4461244a7c24925635dc97f575e43918` |
| `models/card/suggestion_admission_concurrency_test.rb` | `682663858cc0f16fea3e16e115aa62b4c501a6ca4103bc2b3304d159051bcce5` |

Entorno y comando RED exactos, desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile RAILS_ENV=test PARALLEL_WORKERS=1 \
  CI_PROGRESS_BAR=false mise exec -- ruby -e 'Dir.chdir("../.context/handy-934-base"); require File.expand_path("config/environment"); Card::SuggestionRequest.delete_all; exec("./bin/rails", "test", "test/controllers/cards/suggestions_controller_test.rb", "test/models/card/suggestion_queue_test.rb", "test/models/card/suggestion_admission_concurrency_test.rb")'
```

RED: salida 1, 24 casos, 218 aserciones, diez fallos y cero errores u omisiones.
La base admite el trabajo excesivo en las fronteras HTTP y modelo; las dos
conexiones aceptan el mismo usuario. No rechaza las llamadas undécima por cuenta
y trigésima primera global. El proveedor recibe dos turnos consecutivos de una
cuenta, después dos de la otra. El barrido no recupera el aviso perdido.
La sustitución de título activo devuelve 202. Registro local:
`.context/handy-934-full-red.log`.

Comando GREEN, con el mismo entorno y candidatos, desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile RAILS_ENV=test PARALLEL_WORKERS=1 \
  CI_PROGRESS_BAR=false mise exec -- bin/rails test \
  test/controllers/cards/suggestions_controller_test.rb \
  test/models/card/suggestion_queue_test.rb \
  test/models/card/suggestion_admission_concurrency_test.rb
```

GREEN: salida 0, 24 casos, 275 aserciones, sin fallos, errores ni omisiones.
Registro local: `.context/handy-934-full-green.log`.

El ajuste en `card_suggestion_channel_test.rb` termina la solicitud creada en
setup antes de crear otra del mismo usuario. Conserva todas las aserciones de
privacidad y revocación. No se retiró una prueba ni un seam de producción.

### Aislamiento de la prueba concurrente

La prueba necesita transacciones reales entre conexiones, por eso usa
`use_transactional_tests = false`. Las tablas de sugerencias no tienen fixtures:
`fixtures :all` no borra sus filas al pasar a otra clase. La primera versión de
la prueba dejó una fila `pending` del usuario Kevin en la base principal.
La suite paralela pasó en sus bases separadas, pero la prueba de Cable del
navegador ejecutó esa solicitud anterior y no recibió su propia sugerencia.

La versión final limpia las tres tablas de sugerencias en teardown. Se retiró
la fila local residual, se repitió el GREEN y se volvió a ejecutar la suite
de sistema. La exportación RED también se limpia antes de ejecutar candidatos;
no se atribuye a la regresión un fallo causado por restos de pruebas.

## Validación

Con el mismo Ruby limpio, `SAAS=false`, `BUNDLE_GEMFILE=Gemfile` y
`CI_PROGRESS_BAR=false`:

| Comando en `fizzy-custom/` | Resultado |
|---|---|
| `PARALLEL_WORKERS=4 mise exec -- bin/rails test` | Salida 0; 1.875 casos, 7.440 aserciones, seis omisiones, sin fallos ni errores |
| `PARALLEL_WORKERS=1 mise exec -- bin/rails test:system` | Salida 0; 43 casos, 322 aserciones, sin fallos, errores ni omisiones |
| `mise exec -- bin/rubocop -f simple` sobre los diez archivos Ruby del diff | Salida 0; sin infracciones |
| `mise exec -- ruby script/check_agents_docs` | Salida 0; cuatro documentos |
| `git diff --check` | Salida 0 |

## Lo que no se verificó

No se llamó al proveedor real. Los 90 segundos son avance del reloj dentro del
HTTP controlado; no prueban su duración absoluta real ni el costo en moneda.
No se validó MySQL, el modo SaaS, un despliegue ni el worker real de Solid Queue.
La concurrencia de admisión sí usa dos conexiones SQLite reales. El worker se
prueba mediante Active Job y el transporte externo mediante WebMock.

