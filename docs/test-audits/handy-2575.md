# Salud de ticks por columna — Handy 2575

## Autoría previa

- API/modelo: contrato v1 de Dédalo a Fizzy. Protege validación estricta,
  CAS, orden de runs, repetición idempotente y lectura del efecto. Una
  regresión que acepte un run viejo o una propiedad extra debe fallar. Las
  pruebas de automatic_waits sólo cubren filas por tarjeta, no etapas.
  Entrada productiva: PUT/GET del tablero, sin seam adicional.
- Canal: protege aislamiento por cuenta y tablero y revocación al recuperar
  y transmitir. Quitar la comprobación de acceso debe filtrar un snapshot.
  CardSuggestionChannel protege solicitudes por usuario, no etapas. Usa el
  canal real de la aplicación y la identidad de conexión existente.
- Sistema: protege encabezados vacíos, navegación, detalles con teclado y
  touch, vigencia local y entrega Cable con dos sesiones. Quitar el canal,
  refresco local o control de orden debe dejar texto viejo o revertirlo.
  AutomaticWaitsTest sólo observa tarjetas. Usa rutas reales y el controlador
  Stimulus público, sin endpoint de prueba ni tokens nuevos en producción.


## RED histórico y validación

Base completa: `b70a9a15b79cc73bf91f2965092dbb86cd0d118e`.
Antes de implementar, se agregó la candidata
`test/controllers/boards/tick_healths_controller_test.rb` y el fixture v1.
Desde fizzy-custom, Ruby 4.0.9, OSS, PARALLEL_WORKERS=1:

```
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u BUNDLE_PATH -u BUNDLE_BIN -u BUNDLE_GEMFILE SAAS=false PARALLEL_WORKERS=1 mise exec -- ruby bin/rails test test/controllers/boards/tick_healths_controller_test.rb -n /writes/
```

Exit 1: esperaba 201, recibió 404; 1 prueba, 1 aserción, 1 fallo, sin errores.
La petición auténtica llegaba a la ruta ausente. Log local:
`.context/tick-api-red.log` (en el workspace padre). La misma prueba candidata
ahora pasa, junto con el lote de API, modelo y canal: 18 pruebas, 148
aserciones, sin fallos ni errores.

**Excepción RED explícita para modelo, canal y sistema nuevos.** Es una
función nueva: en la base no existe el modelo ni el canal. Cargar sus pruebas
directas en la base produce un error de constante, no un RED de conducta.
No se cuenta como RED. El caso de API anterior comprueba la ausencia histórica
en una frontera existente. La validación alternativa observa las rutas reales,
la persistencia, los rechazos independientes y dos sesiones reales de Cable.
Riesgo histórico sin probar: no se reconstruyó cada interacción del encabezado
en la base; sí se capturó el tablero de la base exportada, con el mismo usuario,
tamaño y tema, antes de compararlo con la nueva vista.

Sistema: `bin/rails test test/system/tick_healths_test.rb`, OSS, un worker:
4 pruebas, 47 aserciones, sin fallos ni errores. Incluye dos sesiones con el
mismo tablero, un tablero privado ajeno y un segundo producto de otra cuenta;
ambas sesiones autorizadas reciben un run sin recarga y los otros no.
También cubre columnas vacías, dos etapas, columna humana, snapshot al
reconectar, duplicados, orden, foco/Enter/Escape, touch CDP y fuente vencida.
El estado de la conexión es texto productivo del detalle; no hay un flag de
prueba. No se retiró ninguna prueba ni seam existente.

Los comandos finales usan el Ruby de `mise which ruby` y anteponen su directorio
al PATH, después de limpiar las variables de Ruby/Bundler. En esta shell,
`mise exec -- ruby` seleccionaba Ruby 4, pero dejaba `/usr/bin` antes en PATH;
los subprocesos de Rails elegían Ruby 3.4. No se modificó el toolchain.

## Evidencia visual y límites

Antes: exportación aislada con `git archive` de la base indicada, nunca el
source checkout ni otro worktree. Copia consistente de la base SQLite local de
QA y mismo usuario, tablero vacío, tema y viewport de 1280×854. Después:
encabezado y detalle en claro/oscuro; móvil 390×844. Capturas locales en
`.context/antes-ticks-*` y `.context/despues-ticks-*`, adjuntas a la tarjeta.

Texto secundario existente, SVG de una sola tinta `currentColor`, sin animación
ni cambio de color por estado. Espacio de una línea fijo para la salud; la fase
puede cambiar sin cambiar el tamaño del encabezado. La columna plegada conserva
su navegación; el detalle es un popover con foco, teclado y toque.

No se verificaron aquí producción, systemd, tokens instalados ni adopción LIVE.
La matriz del registro y el productor real son de Dédalo 2574. El circuito real
y una corrida programada genuina sólo se aceptan después de los gates y las
aprobaciones. Los fixtures de esta tarjeta no acreditan ese paso.

## Corrección exigida por CI tras los primeros PASS

El job `fizzy-custom-test`, run `01a1f113-1fa6-7148-8680-18827cf3559c`,
sobre `5e00fd62f53799d3279f0bc4eff71b9cf2611d13` terminó con exit 1:
3301 pruebas, 18318 aserciones, un fallo, cero errores, cinco omisiones.
Falló únicamente `ActiveRecordSqlRedactionTest#test_every_column_that_looks_secret_is_redacted_or_declared_not_secret`:
`tick_healths.request_digest` no estaba clasificado. No era un defecto de los
límites no bloqueantes de revisión; esos límites se conservan sin cambios.

Autoría previa de la clasificación en la prueba existente:

- Contrato: cada columna cuyo nombre parece una credencial tiene una política
  explícita de registro SQL. Dueño: el inventario de redacción de Fizzy.
- Regresión: agregar una columna `digest` sin clasificación deja la prueba roja.
  La CI anterior es el RED histórico del SHA exacto. Comprobación enfocada:
  `bin/rails test test/lib/rails_ext/active_record_sql_redaction_test.rb -n /every_column/`.
- Cobertura: la prueba existente ya detecta el caso; sólo se amplía su inventario
  `NOT_SECRET` con una razón. No se duplica ni retira ninguna defensa.
- Seam: ninguno nuevo. `request_digest` contiene SHA-256 de evidencia validada
  no secreta para reconocer un reintento. No autentica, no autoriza y no contiene
  el cuerpo original. Es la misma clasificación de `card_automatic_waits.request_digest`.

La corrección renueva ambos gates sobre el nuevo diff y exige otra CI del SHA
final; los PASS anteriores corresponden a la huella d216db8398e1, ronda 1.

La comprobación enfocada repitió el RED local sobre el SHA anterior (1 prueba,
4 aserciones, un fallo: columna sin clasificar). Tras la clasificación, el
mismo comando dio GREEN: 1 prueba, 4 aserciones, sin fallos ni errores.
Logs locales: `.context/tick-classification-red.log` y
`.context/tick-classification-green.log`, en el workspace padre.
