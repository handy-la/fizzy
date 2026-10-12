# Metadata importada y reservas de subida

## Autoría antes de editar pruebas

Base del repo: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.

- **Contrato:** la importación conserva sólo metadata portable del archivo; no
  transporta autorizaciones de cuota. Quitar un adjunto sin una reserva emitida
  por este servidor no crea una reserva. La identidad de una carga debe tener
  un usuario en la cuenta. Una carga válida mantiene su cargo y su ventana
  original al adjuntar y quitar, incluso si cambia la metadata. Dueños:
  `BlobRecordSet`, `UploadReservation`, `AttachmentTracking` y `Account::Storage`.
  Fronteras: ZIP real, filas persistidas, callbacks y saldo exacto.
- **Regresión:** copiar metadata quota_* desde el ZIP permite atribuir reservas
  a otro autor. Borrar la reserva al adjuntar obliga a reconstruir autoridad
  desde metadata. Usar la fecha del detach renueva indebidamente el cupo global.
  Admitir una identidad sin usuario permite cargar a una cuenta ajena.
- **Cobertura:** `BlobRecordSetTest#import preserves blob metadata` comprueba
  columnas pero su metadata está vacía. Se amplía el helper para probar JSON
  serializado, como el export real, y objetos JSON. `UploadReservationTest`
  cubre saldo, rollback, limpieza y borradores, pero no rechaza la identidad
  ajena ni el blob sin emisión server-side. Los casos de adjuntos se adaptarán
  a conservar la fila de emisión sin duplicar bytes. El caso del autor ausente
  se conserva como caso de metadata adulterada con una emisión legítima.
  Las pruebas de cupos entre cuentas y autores usarán membresías explícitas.
- **Seam:** ninguno nuevo. Se usan importación pública, reservas productivas,
  adjuntos, tiempo y almacenamiento local reales. No se sustituye la decisión
  de cuota ni la pertenencia a la cuenta.

Antes de adaptar `UploadReservationConcurrencyTest`: su contrato sigue siendo
que dos conexiones con usuarios autorizados no exceden el saldo disponible.
Una lectura sin lock debe aceptar ambas y fallar. No hay otra prueba con dos
conexiones reales. Se agregan usuarios a las identidades del setup, porque la
nueva frontera rechaza identidades sin membresía antes de leer el saldo. No se
retiran aserciones ni se agrega un seam. La preparación anterior no representa
una llamada autorizada después de este cambio.

Antes de agregar `attached uploads retain issuance without occupying slots`:
protege la admisión de la siguiente carga tras adjuntar veinte archivos, y la
conservación de esos adjuntos durante la limpieza. Una fila de emisión
contada como carga pendiente bloquea la siguiente carga. Los casos de saldo y
rollback no llenan el cupo con adjuntos. No agrega un seam: usa reservas,
`ActiveStorage::Attachment.create!`, saldo y limpieza reales. Las filas de
emisión se deben conservar para autorizar un detach posterior, pero no deben
sumar bytes ni ocupar cupos mientras tengan adjuntos.

## RED histórico y GREEN

Se exportó la base indicada con `git archive` a
`.context/fizzy-931-red`. Se copiaron sólo los dos archivos candidatos de
pruebas. SHA-256 idénticos en RED y GREEN:

- `test/models/storage/upload_reservation_test.rb`:
  `0c9f91893d13df26cac6c8e0d811b4cc348cf0eb28e5ce3511da730ad534eeb0`.
- `test/models/account/data_transfer/active_storage/blob_record_set_test.rb`:
  `9ba033718d9117d41aab1be4b01509602ee737f9d5698aff31b29efac6d499d6`.

Desde `fizzy-custom/`, Ruby 3.4.8 de mise, OSS y SQLite aislado:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bash -c 'cd ../.context/fizzy-931-red && bin/rails test test/models/storage/upload_reservation_test.rb test/models/account/data_transfer/active_storage/blob_record_set_test.rb --include "/forged|outside|portable|persisted|retain_issuance/"'
```

RED: salida 1, seis casos, siete aserciones, seis fallos, cero errores.
La metadata JSON objeto conserva quota_*; la cadena JSON del export pierde
las dimensiones. El blob sin emisión crea una reserva para Mike, quien no
pertenece a la cuenta del blob. La reserva directa acepta esa misma identidad.
Un detach crea otra fila de emisión en lugar de conservar la original. Las
veinte cargas adjuntas pierden las filas necesarias para autorizar un borrado.

GREEN: mismo entorno y argumentos, desde el checkout de la tarjeta, sin el
`bash -c` que entra en la exportación. Salida 0, seis casos y 24 aserciones.
Se conservan dimensiones en ambos formatos; no se crea una reserva sin
emisión; se rechaza la identidad ajena sin filas nuevas; la emisión legítima
conserva identidad y tamaño, y no renueva su ventana al quitar el adjunto.
La carga número 21 se acepta después de adjuntar veinte archivos. La limpieza
no borra los adjuntos después de 31 días.

Los cambios a aserciones de pruebas anteriores distinguen la fila de emisión
de su cargo pendiente. No se retira su cobertura de saldo, avatar, rollback,
borradores y limpieza. **Excepción RED limitada a esas adaptaciones y a las
membresías del setup:** no corrigen un fallo independiente del contrato previo.
La base no tiene el scope `pending`; aplicar sólo esas aserciones produciría
un error de método ausente, que no cuenta como RED. El RED histórico del nuevo
caso de emisión y los GREEN de saldo y limpieza verifican el cambio de modelo.
La concurrencia conserva ambas conexiones y todas sus aserciones de saldo.

## Decisiones

- Se conserva la tabla existente como registro de emisión. No hay migración ni
  tabla importable nueva. El export no transporta reservas.
- `pending` excluye blobs con adjuntos; sólo sus reservas suman bytes y ocupan
  cupos. Los registros de adjuntos siguen contando en el ledger.
- El detach busca la emisión persistida por blob y cuenta. No lee identidad,
  tamaño ni fecha de vencimiento de la metadata; sólo acorta la retención a la
  ventana de URL derivada de la fecha original del servidor y su duración.
- La pertenencia de la identidad se valida bajo los locks de identidad y
  cuenta al emitir la reserva. El importador de usuarios sigue resolviendo
  identidades por email; sus IDs remotos no autorizan una reserva.
- Un adjunto antiguo sin fila de emisión no recibe una reserva reconstruida.
  Los blobs sin reserva conservan el barrido de limpieza anterior. No se
  realiza una reparación de datos históricos desde metadata no confiable.
- La metadata portable admite identificación, análisis, dimensiones, duración,
  ángulo, relación de aspecto y presencia de audio o vídeo. Se descartan campos
  operativos y personalizados. El export real serializa `metadata` como una
  cadena JSON; la importación la decodifica antes de reconstruirla.
- No hay efecto visual, archivos de revisión ni pasos manuales.

## Qué no pude comprobar

No ejecuté MySQL, el entorno SaaS ni una carga real contra S3. Se verificaron
reservas, locks concurrentes, callbacks, importación ZIP y limpieza con SQLite
y Disk. No ejecuté pruebas de sistema: no se modifican pantallas. No se
verificó producción ni se repararon reservas históricas ya creadas.

## Validación final del lote

Desde `fizzy-custom/`, con el entorno limpiado de los comandos anteriores:
`PARALLEL_WORKERS=4 mise exec -- bin/rails test`, salida 0: **1.871 casos,
7.398 aserciones, cero fallos, cero errores y seis omisiones**. Los casos
incluyen importación de cuentas, almacenamiento, autenticación y concurrencia.
El lote enfocado anterior de almacenamiento, importación y controlador de
subidas pasó con 157 casos y 494 aserciones.

`mise exec -- bin/rubocop -f simple` sobre los siete archivos Ruby modificados:
salida 0, cero infracciones. `git diff --check`: salida 0. La raíz mantiene
`CLAUDE.md` en 39.945 bytes; sólo se modifica la guía del sub-repo, en 12.927
bytes. `dedalo.toml` no exige un job CI para `fizzy-custom`; se ejecutó la
suite completa local indicada por el repo.

## Reanudación y actualización de la base

El 2026-10-12 se actualizó la rama con `origin/main` antes de revisar. Los
archivos productivos de cuota de este lote no cambiaron en esa actualización.
La suite completa con el mismo entorno OSS/SQLite y cuatro workers volvió a
pasar: salida 0, **1.908 casos, 7.583 aserciones, cero fallos, cero errores y
seis omisiones**. La evidencia RED conserva su base histórica, donde el arreglo
estaba ausente.
