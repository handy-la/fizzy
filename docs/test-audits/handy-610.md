# Integración de Basecamp: Handy 610

Base del fork: `9a1cc2e5eabdcd24e9f86bcbf70b197c4d1af880`.
Upstream integrado: `d157d2c6816ddfabf6ee09939e2a736e518ad0b2`.
Los ocho commits se unen con merge. No se cambia el código ni las pruebas
importadas. El merge automático conserva RubyLLM y las otras dependencias del
fork. La corrección modifica lógica de paginación; no cambia marcado, estilos
ni textos de pantalla.

## Contratos de las pruebas importadas

### Paginación de columnas y actividad

- **Contrato:** `ColumnPaginationRefreshTest` comprueba que una actualización
  por Cable conserva todas las páginas de una columna. `ActivityPaginationTest`
  comprueba que volver a un día ya cargado no duplica su frame. El dueño es
  `pagination_controller.js`; la frontera es el navegador con Turbo y el
  servidor reales.
- **Regresión:** dejar de observar un enlace después de cargarlo pierde la
  segunda página cuando Turbo elimina su frame. Quitar la comprobación del
  frame existente permite cargar un día dos veces al volver a observarlo.
- **Cobertura:** `card_refresh_test.rb` observa una tarjeta y su editor, pero
  no una columna con más de una página ni el scroll del historial. Los dos
  nuevos archivos cubren consumidores distintos del controlador compartido.
- **Seam:** usan creación de tarjetas, `triage_into`, `broadcast_refresh`,
  enlaces y frames productivos. No agregan API para pruebas. Los helpers de
  scroll, espera y conteo son privados de las clases de prueba.

### Salud y autorización de HotCell

- **Contrato:** los cinco casos de `saas/test/integration/hotcellz_test.rb`
  comprueban la respuesta pública mínima y el acceso del diagnóstico: sin
  sesión se redirige al ingreso; una identidad sin permiso de staff recibe
  403; staff recibe los cuatro diagnósticos. Dueños: rutas SaaS,
  `AdminController`, y los controladores de `hotcell-client` 0.6.0. La frontera
  es HTTP, con el prefijo de cuenta retirado mediante `untenanted`.
- **Regresión:** montar el diagnóstico sin heredar de `AdminController`
  permite acceso a personas sin permiso. Publicar el diagnóstico completo
  desde `/hotcellz` expone información de la celda.
- **Cobertura:** el archivo anterior usaba un controlador propio que upstream
  retira. Los nuevos casos conservan la frontera de autorización y comprueban
  la respuesta nueva, que agrupa los checks bajo `cells`. La redirección sin
  sesión es un cambio expreso de upstream, confirmado por `715a9ea00`.
- **Seam:** peticiones HTTP y sesiones productivas; no se agrega ningún seam.

### Telemetría de HotCell

- **Contrato:** los dos casos de `saas/test/lib/hotcell_telemetry_test.rb`
  comprueban una línea de log por evento y un contador por resultado.
  Dueños: la inicialización SaaS, `HotCell::LogSubscriber` y
  `Yabeda::HotCell` de las gemas 0.6.0.
- **Regresión:** duplicar el subscriber duplica el log; omitir
  `Yabeda::HotCell.install!` deja el contador sin incrementar.
- **Cobertura:** las antiguas pruebas unitarias miraban la implementación
  retirada; estos casos verifican que la aplicación conecta las gemas al
  evento. Las pruebas de las gemas cubren los valores y errores individuales.
- **Seam:** `perform.hot_cell` es el evento productivo de los clientes.
  `Yabeda::TestAdapter` pertenece al proveedor; no se agrega API productiva.

## RED histórico y GREEN de paginación

Se exportó la base con `git archive` a `.context/handy-610-base`, sin usar
otro worktree ni el source checkout. Se copiaron únicamente las dos pruebas
candidatas desde el SHA de upstream indicado arriba.

SHA-256 de las candidatas sin cambios:

- `column_pagination_refresh_test.rb`:
  `03cdf5dac01b188f1df8a75a43e2d53a4953632404be4b0b2c5a28dcd8c88b36`.
- `activity_pagination_test.rb`:
  `77aa6a98e2ae8297ff3a7221ecec264c84806e8036c183ad74921b5b1f5f9e92`.

Desde `fizzy-custom/`, con Ruby 3.4.8 de mise, Chromium y SQLite:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ruby -e 'Dir.chdir("../.context/handy-610-base"); exec("./bin/rails", "test", "test/system/column_pagination_refresh_test.rb", "test/system/activity_pagination_test.rb")'
```

RED: salida 1; 2 casos, 9 aserciones, 1 fallo, sin errores. Después de
`broadcast_refresh`, la columna tenía 15 tarjetas visibles en lugar de 19.
El caso de actividad pasó: protege una posible regresión de la corrección,
no reproduce un segundo incidente. Evidencia local: `handy-610-red.log`.

GREEN: mismo entorno y las mismas candidatas, ejecutadas en `fizzy-custom/`
con `mise exec -- bin/rails test test/system/column_pagination_refresh_test.rb
test/system/activity_pagination_test.rb`: salida 0, 2 casos, 9 aserciones,
sin fallos ni errores. Evidencia local: `handy-610-green.log`.

## Sustitución de pruebas y seams de SaaS

La sustitución pertenece a upstream `7323bbfba` y `7ef801284`, después de la
actualización `0200eda52`. Se leyeron las pruebas retiradas completas, sus
implementaciones y los consumidores en `saas/`, `app/`, `config/` y `test/`.
Los métodos retirados no tienen otros consumidores en el árbol final. El
initializer conserva la instalación de métricas desde la gema. Las operaciones
`example.echo` y `example.reopen` pasan a `health.echo` y `health.reopen` de
`hotcell-server`; `operations/health.rb` las carga para el servidor real.

| Prueba o seam retirado | Fallo que detectaba y cobertura restante | Decisión y riesgo |
|---|---|---|
| `saas/test/controllers/hotcellz_controller_test.rb` (10 casos), `HotcellzController` | Respuesta mínima, permisos, checks, fecha, host y errores sin celda. Los cinco casos de integración nuevos conservan la frontera de la app. `hotcell-client/test/controllers_test.rb` y `diagnosis_test.rb` cubren estado HTTP, forma de checks, fecha, host y celda ausente. | Sustituir el controlador y su suite. Cambian la redirección sin sesión y el formato JSON de staff; no conservar expectativas de la API anterior. Falta ejecutar la integración con el bundle SaaS completo. |
| Cuatro casos de `saas/test/lib/cell_test.rb`, `Cell.diagnostics`, `echo`, `reopen`, `round_trip`, `CheckFailed`, `silent_client` y `staging_client` | Detectaban trabajo en una consulta de control, checks incompletos, bytes diferentes y entrada copiada. `hotcell-client/test/diagnosis_test.rb` cubre esas cuatro condiciones con transporte, sockets y servidor reales o dobles del proveedor. | Sustituir los métodos y sus pruebas. Los dobles privados sólo servían a las pruebas retiradas. Se conservan los diez casos de registro, tiempos y configuración de Active Storage de la app. |
| `saas/test/lib/yabeda/hot_cell_test.rb` (15 casos), colector y log propios | Detectaban valores ausentes, clasificaciones, errores que se propagaban, logs incorrectos y reportes duplicados. `yabeda-hotcell/test/collect_test.rb`, `perform_test.rb` y `hotcell-client/test/log_subscriber_test.rb` comprueban los valores, las causas y los errores; los dos casos nuevos de la app observan su instalación. | Sustituir el código copiado por las gemas fijadas a 0.6.0. El subscriber de log ya no reporta fallos por su cuenta. Las pruebas de la gema no demuestran por sí solas que la app SaaS lo inicializa bien; ese límite queda declarado. |

### Evidencia independiente de las gemas

Se consultó `basecamp/hotcell`, tag `v0.6.0`, commit
`ffc92154a379379e56b671938b0947e21740b1d8`, dentro de `.context/`.
Se compararon las implementaciones con las gemas 0.6.0 descargadas de
RubyGems. Las pruebas usan un bundle temporal que evalúa el Gemfile OSS del
fork y agrega los paths de `hotcell-core`, `hotcell-client`, `hotcell-server`
y `yabeda-hotcell`; no altera ninguno de los bundles de la aplicación.

Con `BUNDLE_GEMFILE=../.context/handy-610-gems/Gemfile.audit`, Ruby de mise
y las variables Ruby heredadas retiradas:

```bash
mise exec -- bundle exec ruby \
  -I../.context/handy-610-hotcell/hotcell-core/lib \
  -I../.context/handy-610-hotcell/hotcell-server/lib \
  -I../.context/handy-610-hotcell/hotcell-client/test \
  -e 'ARGV.each { |path| require File.expand_path(path) }' \
  ../.context/handy-610-hotcell/hotcell-client/test/diagnosis_test.rb \
  ../.context/handy-610-hotcell/hotcell-client/test/controllers_test.rb \
  ../.context/handy-610-hotcell/hotcell-client/test/log_subscriber_test.rb
```

La primera ejecución dio 21 casos y un fallo: una aserción compara todo el
stdout/stderr de un subproceso con `StaffController`; Bundler agrega avisos de
extensiones locales ausentes. La clase correcta aparece en la salida. Los
otros 20 casos pasan: 69 aserciones, sin omisiones, con selección
`-n '/^(?!.*inherits_from_the_configured_parent)/'`. Se comprobó por separado
en un proceso limpio que `DiagnosticsController.superclass == StaffController`:
salida 0. No se cambió ni se eliminó la prueba del proveedor.

El mismo runner, con el directorio de test de `yabeda-hotcell` y los archivos
`collect_test.rb` y `perform_test.rb`, dio salida 0: 10 casos, 20 aserciones.

Además se aplicaron cuatro mutaciones controladas, sólo en la copia temporal
del proveedor: omitir el rechazo de bytes diferentes, omitir el rechazo de
entrada copiada, omitir el incremento del contador, y omitir el log. Las
pruebas respectivas fallaron con salida 1. Se restauró cada archivo al
terminar. Evidencia: `handy-610-sensitivity-{bytes,staged,metrics,logs}.log`.
Estas mutaciones prueban sensibilidad de la cobertura que queda; no se
presentan como RED histórico de SaaS.

## Excepción RED explícita de SaaS y límites

`SAAS=true BUNDLE_GEMFILE=Gemfile.saas mise exec -- bundle check` no puede
resolver `https://github.com/basecamp/rails-structured-logging`: GitHub devuelve
`Repository not found`. Ese fallo de dependencias no es RED. No se dispone
del bundle privado para ejecutar las pruebas de integración SaaS contra la
base ni contra el merge. La tarjeta corresponde a la instalación OSS local;
`tmp/saas.txt` no existe. La actualización de SaaS se conserva porque es parte
del merge solicitado, con la excepción RED sometida al revisor.

Validación alternativa: lectura de rutas e inicialización, las pruebas del
proveedor descritas arriba y las suites OSS completas. Quedan sin verificar
la inicialización SaaS completa, su integración HTTP con sesiones de Fizzy,
un despliegue SaaS y la imagen de HotCell en producción. No se afirma que las
pruebas del proveedor sustituyan esas comprobaciones de integración.

## Validación del fork

Todas las pruebas Rails usan Ruby 3.4.8, SQLite, `SAAS=false`,
`BUNDLE_GEMFILE=Gemfile`, `CI_PROGRESS_BAR=false` y las variables Ruby heredadas
retiradas como en el comando RED.

| Comando en `fizzy-custom/` | Resultado |
|---|---|
| `PARALLEL_WORKERS=4 mise exec -- bin/rails test` | Salida 0; 1.762 casos, 6.830 aserciones, 6 omisiones |
| `PARALLEL_WORKERS=1 mise exec -- bin/rails test:system` | Salida 0; 38 casos, 215 aserciones, sin omisiones |
| `mise exec -- bin/rubocop -f simple` sobre los 11 archivos Ruby modificados | Salida 0, sin infracciones |
| Revisión completa de estilo, merge y exportación de la base | Ambas dan salida 1, con las mismas 781 infracciones; ninguna nueva |
| `mise exec -- bin/bundle-drift check` | Salida 0; bundles OSS y SaaS sincronizados |
| `test/setup-phases-test` | Salida 0; 26 aserciones |
| `mise exec -- bash test/dev-port-test`, con variables Ruby heredadas retiradas | Salida 0; 15 aserciones, tanto en la base como en el merge |
| `mise exec -- ruby script/check_agents_docs` | Salida 0; cuatro documentos |
| `mise exec -- bin/bundler-audit check --update` | Salida 0; sin vulnerabilidades |
| `mise exec -- bin/importmap audit` | Salida 0; sin paquetes vulnerables; bridge sin versión se omite |
| `mise exec -- bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` | Salida 0; cero avisos, seis avisos previamente ignorados |
| `mise exec gitleaks@8.28.0 -- bin/gitleaks-audit` | Salida 0; sin secretos detectados |

Una ejecución inicial de `test/dev-port-test` fuera de `mise exec` falló por
el entorno de la shell y la selección de Ruby en los sandboxes. No se cambió
el runner ni el código de puertos: ambos son idénticos a la base y pasan con
Ruby seleccionado antes de entrar en los sandboxes. Los logs locales quedan
en `.context/handy-610-*.log`; los resultados y sus límites quedan aquí para
la revisión aunque el worktree se retire.
