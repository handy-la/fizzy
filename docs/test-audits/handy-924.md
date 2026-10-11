# Revocación de acceso y notificaciones

## Autoría antes de editar las pruebas

Base productiva: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.

- **Contrato:** tras revocar el acceso, la web (lista, bandeja y render de
  Turbo), el correo y push no exponen avisos del tablero. La revocación borra
  las notificaciones dentro de su transacción. Dueños: `Access`,
  `Notification`, `NotificationsController`, `Notifications::TraysController`,
  `Notification::Bundle` y `Notification::Pushable`. Fronteras: peticiones HTTP,
  render de los parciales productivos y ejecución de los jobs de entrega.
- **Regresión:** conservar la limpieza solo en el job deja filas después de
  `Access#destroy!`. Omitir el filtro de acceso en un consumidor expone una
  fila pendiente cuando la limpieza falla. Una asociación cargada antes de
  revocar no debe autorizar una entrega posterior.
- **Cobertura:** `access_test.rb` solo comprobaba el resultado después de
  ejecutar la limpieza. `notifications_controller_test.rb` y
  `notifications/trays_controller_test.rb` solo cubrían usuarios autorizados.
  `notification/pushable_test.rb` y `notification/bundle_test.rb` comprobaban
  cuentas canceladas, pero no accesos revocados. El archivo nuevo prueba el
  mismo incidente en sus distintas fronteras, con controles positivos.
- **Seam:** ninguno nuevo. Se usan rutas, parciales y jobs productivos. Para
  aislar el filtro de cada consumidor se elimina un `Access` con `delete`
  (sin callbacks) y se fuerza el fallo del job de limpieza. Esto conserva
  avisos antiguos, como una limpieza fallida o un aviso creado por un job
  retrasado. El mock de push solo observa si el transporte procesa un target;
  no implementa la autorización. Los otros casos usan `destroy!` para probar
  el borrado síncrono y su rollback real.

## Evidencia

La suite completa detectó un dato de prueba incompatible con el nuevo control:
`Notification::BundleMailerTest#test_groups_notifications_by_board,_sorted_alphabetically`
creaba un aviso privado para David sin darle acceso a ese tablero.
Antes de modificar ese caso se registra su autoría:

- **Contrato:** el correo agrupa por tablero y ordena sus nombres para un
  destinatario autorizado; dueño `Notification::BundleMailer`, frontera MIME.
- **Regresión:** perder el agrupamiento o el orden rompe sus aserciones actuales.
- **Cobertura:** se conserva el caso existente y todas sus aserciones. Solo se
  da acceso al destinatario para que el caso siga probando presentación.
- **Seam:** `Board#accesses.grant_to`, usado por la administración productiva.

Excepción RED explícita para este ajuste de datos: la prueba de orden ya existe
y pasa en la base; no se agrega una nueva detección de regresión. Con el arreglo
y sin el acceso, la suite falló por un encabezado en lugar de dos. El permiso
repone su precondición válida; la autorización negativa se verifica mediante
los casos nuevos y su RED histórico. No se retira ninguna aserción.

Prueba candidata: `test/integration/notification_access_revocation_test.rb`.
SHA-256 idéntico en RED y GREEN:
`a43d226593c01cfcbd897ad652166c343e8b61524b0e4ab7197aa43e69c5ca29`.

Comando desde `fizzy-custom/`, con Ruby 3.4.8 de mise y SQLite:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/integration/notification_access_revocation_test.rb
```

RED histórico: se restauraron temporalmente solo los archivos productivos de
la base con `git show HEAD:<archivo>`, sin alterar la prueba; después de que
terminó el runner se repuso el arreglo. Salida 1: 13 casos, 80 aserciones,
13 fallos, cero errores. Fallos observados: HTML y JSON contenían el aviso
revocado; el correo enviaba contenido del tablero; push procesaba un target;
la revocación dejaba filas; marcar el aviso como leído devolvía 204.

GREEN: mismo comando y archivo. Salida 0: 13 casos, 114 aserciones, sin
fallos ni errores. Incluye conservar los avisos de otro tablero, enviar solo
el contenido permitido de un correo mixto, rollback y descarte de un push
serializado antes de borrar su aviso.

Suite completa con el mismo entorno y `PARALLEL_WORKERS=4`, comando
`mise exec -- bin/rails test`: salida 0, 1.878 casos, 7.486 aserciones,
cero fallos, cero errores y 6 omisiones. Registro local:
`.context/handy-924-suite.log` del workspace.

Rubocop sobre los 13 archivos Ruby del lote: salida 0, sin infracciones.
La evidencia local de ejecución está en `.context/handy-924-red.log` y
`.context/handy-924-green.log` del workspace; los resultados comprobables se
registran aquí para no depender de esos archivos temporales.

## Límites

La comprobación se hace al consultar y al preparar el render o la entrega.
No recupera contenido que ya llegó al navegador, al correo o al proveedor
push antes de revocar. No serializa una entrega en curso con una revocación
concurrente. El service worker conserva el contenido recibido; el bloqueo de
nuevos envíos se aplica en el servidor. Las pruebas usan SQLite en modo OSS;
no comprueban MySQL, SaaS ni proveedores externos.
No se ejecutó la suite de navegador: el cambio conserva el diseño y el texto;
los consumidores web se comprobaron con peticiones HTTP y render con caché.
