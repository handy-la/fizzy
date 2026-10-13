# Handy 928: dueño y sesión de las notificaciones web

## Autoría registrada antes de editar las pruebas

- **Contrato:** un endpoint sólo entrega notificaciones del usuario y la sesión
  que lo autorizaron. Cerrar o revocar esa sesión impide entregas nuevas.
  `Push::Subscription`, `Session` y los controladores HTTP son los dueños.
  La UI sólo muestra una suscripción activa después de verificarla en servidor.
  El service worker verifica también las entregas que ya estaban en tránsito.
- **Regresión:** conservar el registro al salir, aceptar el mismo endpoint para
  dos usuarios, enviar con una sesión eliminada o habilitar la UI antes de
  consultar al servidor vuelve a exponer notificaciones del usuario anterior.
  Omitir el registro firmado del mensaje o su comprobación permite mostrar
  una entrega anterior después de que cambie el usuario.
- **Cobertura:** `users/push_subscriptions_controller_test.rb` comprobaba alta,
  duplicados del mismo usuario y borrado individual. `sessions_controller_test.rb`
  comprueba cookies y Cable. `notification/push_target/web_test.rb` comprueba
  envío con registros y sin registros. `web_push/persistent_request_test.rb`
  comprueba el destino HTTP, pero no la autorización del mensaje en el navegador.
  Ninguno comprobaba cambio de dueño, revocación externa ni reconciliación.
  Se amplía el primer archivo. Los casos JavaScript observan la frontera propia
  del navegador: espera de HTTP, permiso persistente, red y mensaje en tránsito.
- **Seam:** las peticiones usan rutas, sesiones y registros productivos. El
  caso de unicidad escribe mediante Active Record para observar la restricción
  de base de datos, independiente del filtro HTTP. El caso del payload captura
  el mensaje en `WebPush.payload_send`, frontera existente con el proveedor.
  Los casos JavaScript cargan los módulos productivos con Node VM y sustituyen
  Stimulus, HTTP, DOM y PushManager; el caso de logout toma la acción del formulario
  productivo. No se añade una API exclusiva de pruebas. El wrapper Ruby incluye
  estos casos en la suite normal. Requiere Node además de Ruby.

La prueba existente de alta duplicada ahora registra mediante HTTP para conservar
la sesión autorizada. Los setups de `Notification::PushTarget::WebTest` y
`NotificationDeliveryTest` agregan una sesión de fixture al registro existente;
conservan sus aserciones de entrega positiva. No se retira ninguna prueba ni seam.

## Autoría del ajuste de errores temporales

- **Contrato:** una excepción de red, un 5xx o un HTTP 200 sin verificación
  conserva el endpoint y no activa la UI. Sólo la ausencia de usuario o un
  rechazo definitivo de autorización cancela la suscripción. Dueño:
  `verifyPushSubscription`; frontera: transporte HTTP y PushManager.
- **Regresión:** cancelar el endpoint cuando una navegación ocurre sin red
  deja al usuario sin push después de recuperar la conexión. El worker y la
  sesión ya bloquean las entregas que no pueden autorizarse.
- **Cobertura:** se corrigen los casos existentes de red y HTTP 200, cuyo
  esperado anterior exigía una cancelación innecesaria. Se añade 503 porque
  una respuesta HTTP fallida no recorre el catch de una excepción de red.
- **Seam:** se conserva el mismo harness Node y las mismas APIs productivas;
  no hay un nuevo seam ni un cambio en las pruebas de entrega del worker.

## RED histórico

Base completa del repo: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.
Se exportó con `git archive` a `.context/handy-928-base`, sin otro worktree ni
source checkout. Se copiaron únicamente las candidatas de controller y JavaScript.
Entorno OSS, SQLite, Ruby 3.4.8 de mise y Node 26.8.1. No se usaron proveedores reales.

Desde `fizzy-custom/`, para los cinco casos que observan contratos anteriores:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ruby -e 'Dir.chdir("../.context/handy-928-base"); exec("./bin/rails", "test", "test/controllers/users/push_subscriptions_controller_test.rb", "-i", "/logout_removes|another_user_cannot|revoked_without|payload_carries|storage_rejects/")'
```

Salida 1: cinco fallos de aserción, sin errores. Logout conserva el endpoint;
el segundo usuario recibe 201 en lugar de 409; una sesión eliminada todavía
invoca `web_push_pool.queue`; el mensaje no lleva URL de verificación; la base
permite guardar el mismo endpoint para dos usuarios. Log local:
`.context/handy-928-server-final-red.log`.

Desde la exportación `.context/handy-928-base/`:

```bash
node --experimental-vm-modules --test \
  --test-name-pattern='existing subscription|belonging|unverified HTTP|network failure|logout waits|service worker' \
  test/javascript/push_subscriptions_test.mjs
```

Salida 1: nueve fallos de aserción. La UI se activa antes de HTTP o ante rechazo, HTTP 200 o error de red;
logout no espera la cancelación y el worker muestra mensajes sin consultar al servidor, incluso
ante 403 o falta de red. Log: `.context/handy-928-js-red.log`.

Los casos de verificación HTTP adicionales comprueban la nueva interfaz:
registro correcto sin cambios, cambio de usuario, claves incorrectas, nueva
sesión del mismo usuario, otro dispositivo y tokens de entregas anteriores.
El RED histórico anterior demuestra el defecto de autorización que corrigen;
no se cuenta como RED la ausencia de la ruta nueva en la base.

**Excepción RED acotada:** el caso JavaScript de arranque público llama al nuevo
helper que no existe en la base. Un error de import no demostraría la regresión,
por eso se excluye del RED histórico. Su GREEN comprueba que se llama
`unsubscribe()` sin petición de alta cuando no hay usuario. La revocación sin
logout sí tiene RED independiente en HTTP y en el worker. El caso de fallo de
cancelación durante logout comprueba que el formulario continúa para que el
servidor retire sus registros; el RED de espera cubre el mismo ciclo de vida.

## RED del error temporal detectado en revisión

Se exportó la primera corrección, SHA completo
`89b52034aa1b2b79735373d7bee760cc3f6cb53f`, a
`.context/handy-928-first-fix/`. Allí se copió la candidata JavaScript final.
Desde esa exportación, con Node 26.8.1:

```bash
node --experimental-vm-modules --test \
  --test-name-pattern='network failure|transient server|unverified HTTP' \
  test/javascript/push_subscriptions_test.mjs
```

Salida 1: tres fallos de aserción porque se cancelaba el endpoint ante excepción,
503 o HTTP 200 sin autorización. El mismo comando desde `fizzy-custom/` pasó
los tres casos, salida 0. Logs: `.context/handy-928-transient-red.log` y
`.context/handy-928-transient-green.log`. El registro firmado y el worker
conservan la defensa de privacidad mientras la UI no activa push sin verificación.

## GREEN y reproducción final

Desde `fizzy-custom/`, con el mismo entorno limpio:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=2 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test
```

La suite incluye las candidatas y el wrapper Node. Los nueve casos JavaScript
seleccionados pasan con el mismo comando RED desde el repo corregido; el archivo
completo pasa doce casos. La suite de sistema se ejecuta con las mismas variables,
`PARALLEL_WORKERS=1` y `mise exec -- bin/rails test:system --seed 40822`.

La primera suite de sistema detectó una regresión introducida al retrasar
`clearCache`: el ingreso con código comparte ese controlador y deshabilita
su campo después del primer submit. El segundo submit omitía el código. La
exportación base pasó 43 casos con esa semilla. La corrección conserva
`clearCache` síncrono y usa la acción `logout` sólo en los dos formularios de
salida. La suite final pasó 43 casos, 322 aserciones, sin fallos ni omisiones.
Log: `.context/handy-928-system-green.log`.

La suite general final pasó 1.878 casos y 7.442 aserciones, sin fallos ni
errores; informó seis omisiones. Salida 0. Log: `.context/handy-928-suite.log`.
Los cinco casos HTTP seleccionados pasan con `bin/rails test test/controllers/users/push_subscriptions_controller_test.rb -i '/logout_removes|another_user_cannot|revoked_without|payload_carries|storage_rejects/'`:
cinco casos, 27 aserciones, salida 0. Logs de GREEN:
`.context/handy-928-server-selected-green.log` y
`.context/handy-928-js-selected-green.log` (nueve casos, salida 0).
El wrapper de la suite ejecuta los doce casos completos del navegador simulado.
Rubocop pasó los diez archivos Ruby modificados y `script/check_agents_docs`
pasó sus cuatro archivos.

SHA-256 de las candidatas del lote anterior, copiadas a la base:

- Controller: `e9f6fb8cbc9bb9bc7931c2b6925fdf7a0cce8ed9287b84ccd5593213cd38f871`.
- JavaScript: `7e9d0936252a36d51e56189c024dddbe160b37a9b6d7e5bf611dd2cf83a0b2ec`.


## Decisiones y límites

- La migración retira registros previos: no tienen prueba de sesión ni dueño
  global único. Los usuarios deben activar push otra vez. No se toca el historial
  de notificaciones. Una vuelta atrás no restaura los registros retirados.
- El índice global usa SHA-256 para no depender del prefijo de 255 caracteres
  que MySQL aplica al índice antiguo de endpoint por usuario.
- Una sesión borrada por SQL queda fuera del scope `active`, incluso si el
  borrado no ejecuta callbacks. El worker también consulta la sesión al recibir
  mensajes con un token ligado al registro anterior, no al endpoint reutilizado.
- Sin red o sin autorización, el worker descarta el mensaje y no cambia el badge.
  Una reconciliación sin red conserva la suscripción local sin activar la UI.
  Sólo un rechazo definitivo o la falta de usuario la cancela.
- No se verificó entrega real por FCM, Firefox o Apple, ni ejecución SaaS/MySQL.
  La migración se ejecutó en SQLite y ambos schemas incluyen el contrato nuevo.
  Los casos Node sustituyen APIs del navegador y transporte; Chromium prueba la
  navegación real, pero su configuración deniega permisos de notificación.
- El cambio no borra una notificación que el sistema operativo ya mostró antes
  de cerrar sesión. La comprobación del worker requiere su versión actualizada.

## Integración con main del 13 de octubre

El rebase incorpora los controles ya publicados de cuota push y limpieza de
caché. Conserva `register_for` y su lock de usuario, `client_id`, los límites de
alta y fan-out, y la caché pública del worker. La autorización de usuario y sesión
se comprueba antes de registrar; el envío combina el scope `active` y el límite.
El logout limpia la caché antes de cancelar push y enviar el formulario. Un fallo
al limpiar la caché impide el envío; un fallo local de PushManager permite que
el servidor revoque los registros. El ingreso conserva la acción de limpieza
actual y deshabilita el código en `turbo:submit-start`, como hace main.

Autoría de las adaptaciones de pruebas, antes de editarlas:

- **Contrato:** el envío queda limitado a cinco registros activos; el logout
  sólo sale después de limpiar datos privados. Se conservan las comprobaciones
  existentes de privacidad, token rotado, cuota y limpieza de sesión.
- **Regresión:** combinar mal los cambios puede enviar sin sesión, quitar el
  límite, impedir rotaciones o enviar logout antes de borrar datos privados.
- **Cobertura:** se conservan las pruebas publicadas de cuotas y caché. El caso
  de fan-out copia filas por SQL y necesita una huella distinta por endpoint
  para cumplir la nueva restricción. El harness Node debe ofrecer `Turbo.cache`
  usado por main. Se amplía el mismo caso de logout para comprobar que una
  limpieza fallida no permite salir; no se duplica otra capa.
- **Seam:** las pruebas usan las mismas rutas, modelos, formulario y APIs de
  navegador productivas. El helper privado de caché tiene dos consumidores
  productivos (`clearCache` y `logout`). No se añade API exclusiva de pruebas.

El RED histórico de cuotas pertenece al main publicado y a su documento
`docs/test-audits/handy-940.md`. El RED de privacidad y sesión de esta tarjeta
permanece arriba. La adaptación de la fila SQL cambia sólo su huella y conserva
la aserción independiente de cinco destinos; no se cuenta una violación de
unicidad como RED de fan-out. La suite general de integración pasó 2.059 casos y 8.688 aserciones, sin
fallos ni errores; seis omisiones. Los casos enfocados pasaron 63 casos y
250 aserciones. Node pasó 13 casos. Rubocop pasó once archivos Ruby.

La prueba HTTP de concurrencia publicada usaba un bearer sin sesión de navegador.
Ahora registra mediante la cookie obtenida por el ingreso real con código, porque
push exige una sesión revocable. Mantiene seis peticiones paralelas y las mismas
aserciones independientes: cinco altas, un 429 y cinco filas. Se limpia sólo la
sesión creada por ese caso, además de su cuenta. No se reduce la cobertura del
lock de cuota ni se cambia un esperado para ocultar su fallo. La frontera sigue
siendo HTTP concurrente y no se agrega un seam de autenticación.


El caso de fallo de limpieza se ejecutó también contra una exportación de la
revisión previa al rebase, `feac7b695ede5219fdde479014cd448de9091c75`.
La exportación `.context/handy-928-before-main-integration/` recibió únicamente
la candidata Node. Con Node 26.8.1, desde esa exportación:

```bash
node --experimental-vm-modules --test --test-name-pattern='private cache deletion' \
  test/javascript/push_subscriptions_test.mjs
```

RED: salida 1, un fallo `Missing expected rejection`; el logout ignoraba la
caché privada del main nuevo. El mismo comando desde el repo integrado dio
GREEN: salida 0, un caso. Logs: `.context/handy-928-cache-integration-red.log`
y `.context/handy-928-cache-integration-green.log`. La integración del transporte
concurrente conserva las aserciones de capacidad; no se cuenta su 403 inicial
por falta de sesión como RED de cuota.

Candidatas de integración:

- Node: `3c3c8c21e3a9f98fd4433fcb6c2751134a65afaa40479d01d102eb3f1e33c635`.
- Concurrencia HTTP: `d67b4f068b5ef42b6532400d83f9e71a1ce0561e94c1c1a88ca9678a601fc6d6`.

## Excepción de presupuesto autorizada

El 13 de octubre la persona autorizó una ronda más de `bin/signoff`, con
`CHANGE_REVIEW_MAX_ROUNDS=4`, porque main avanzó durante el aterrizaje.
Se conserva la serie y exactamente este contexto:

> Vincular las notificaciones push al usuario y la sesión, reconciliar el navegador al cambiar de identidad y bloquear entregas después de revocación.

No se reinicia el contador ni se omite la revisión. La instrucción de la persona
es detener la integración si esa revisión encuentra un problema real; con ambos
PASS, enviar de inmediato y registrar el aterrizaje.

La suite de navegador de integración se ejecutó con el mismo entorno OSS,
`PARALLEL_WORKERS=1` y `bin/rails test:system --seed 40822`. La primera ejecución
terminó con 61 casos, cero fallos y un error al buscar «Invite people» en
`BackLinkNavigationTest`. Se conservó esa prueba sin cambios. Sus cinco casos
pasaron sobre una exportación aislada de `origin/main`,
`fb2af95ebcd8317391d7b3c7f715d22f97e81ffb`, con la misma semilla. La repetición
completa del repo integrado pasó los 61 casos, sin fallos, errores ni omisiones.
No se atribuye una causa al error transitorio ni se cuenta como RED de push.
Logs: `.context/handy-928-system-final-integration.log`,
`.context/handy-928-back-link-baseline.log` y
`.context/handy-928-system-final-integration-rerun.log`.
