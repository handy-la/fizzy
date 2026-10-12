# Handy 933: integridad de blobs importados

## Autoría (antes de editar las pruebas)

- Contrato: BlobRecordSet debe rechazar tamaños negativos o no enteros y comparar el tamaño y MD5 del manifiesto con los bytes leídos del ZIP antes de insertar blobs. Account::Import debe eliminar filas y objetos parciales al fallar. Una importación válida debe guardar los valores medidos y contabilizarlos. La base debe rechazar un byte_size negativo incluso por SQL.
- Regresión: conservar byte_size sin medir, omitir la comparación del checksum, conservar metadata derivada, o reconciliar una importación parcial permite un consumo incorrecto. Los casos negativos observan ausencia de blobs, uploads y adjuntos; el positivo observa el objeto, la fila y el consumo.
- Cobertura: blob_record_set_test comprobaba que los valores declarados se conservaban, sin cuerpo de archivo. file_record_set_test comprobaba contenido y claves nuevas, pero no tamaño persistido. import_test tiene round-trip y purga por límites ZIP; se amplían para diferencias del manifiesto y para la nueva medición previa a upload. La defensa SQL tiene riesgo propio: insert_all! omite validaciones.
- Seam: se usan import/check públicos, ZIP real, almacenamiento de prueba y update_column para comprobar el CHECK. No se agrega API productiva para pruebas. La notificación service_upload.active_storage observa cargas reales.

## Evidencia

Base: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72` de fizzy-custom. Se aplicaron las pruebas candidatas antes de cambiar producción: 26 casos, 6 fallos, sin errores (salida 1). Una importación negativa completó sin rechazo.

Se repitió el RED con todas las pruebas finales en una exportación temporal aislada de `git archive` de esa base, sin compartir la base SQLite del worktree. Archivos candidatos: los tres tests de Active Storage, import_test y blob_key_traversal_test del diff final. Ruby 3.4.8, OSS, SQLite; `mise exec` seleccionó Ruby desde fizzy-custom antes de entrar en la exportación.

Comando desde fizzy-custom (TASK_RED_DIR identifica esa exportación):

```bash
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u BUNDLE_PATH -u BUNDLE_BIN \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bash -c 'cd "$1" && bin/rails test test/models/account/data_transfer/active_storage test/models/account/import_test.rb test/integration/blob_key_traversal_test.rb' handy-933-red "$TASK_RED_DIR"
```

Resultado: 35 casos, 111 aserciones, 9 fallos, 0 errores, salida 1. Se aceptaron tamaños falsos y un cuerpo ausente, no se rechazó el UPDATE negativo, se conservó metadata derivada y quedó un objeto tras el error por archivo huérfano. El noveno fallo corresponde a la expectativa nueva de cero uploads ante un ZIP inflado; la base anterior subía un archivo antes de detectar el límite. Logs de trabajo: `.context/handy-933-red-final.log` y `.context/handy-933-red-purge.log` de la raíz; este documento conserva los resultados sin exigir esos archivos locales.

GREEN: mismo selector de pruebas y mismo entorno, desde el repositorio corregido. 35 casos, 186 aserciones, 0 fallos, 0 errores, 0 omisiones; salida 0. El comando es el anterior sin `bash -c`, ejecutando directamente `bin/rails test` con los mismos tres selectores.

Suite completa: el mismo entorno con `mise exec -- bin/rails test`: 1873 casos, 7455 aserciones, 0 fallos, 0 errores, 6 omisiones; salida 0. La primera ejecución encontró que el ZIP de traversal no tenía cuerpo; se corrigió su fixture, sin quitar sus comprobaciones HTTP. `bin/rubocop` sobre los nueve archivos Ruby modificados: sin infracciones. `script/check_agents_docs`: cuatro archivos válidos. `git diff --check`: sin errores.

Migración aplicada en SQLite de prueba: CHECK agregado con éxito. El UPDATE negativo de la prueba confirma la defensa SQL. schema_sqlite.rb se generó mediante db:migrate, y schema.rb se sincronizó con el mismo CHECK y versión para MySQL.

No pude verificar: suite SaaS, MySQL, servicio S3 real ni pruebas de sistema. La validación se ejecutó con almacenamiento Disk y SQLite. No hay cambio visual. El CHECK falla si ya existen filas negativas; no reescribe ni atribuye tamaños de archivos históricos.

## Ampliación tras ejecutar la suite

La medición previa detiene un ZIP inflado antes de subir objetos. Se conserva esa defensa y se cambia su expectativa a cero uploads. Para conservar la cobertura de purga real, se agrega un archivo sin metadata al final de una exportación válida: FileRecordSet debe fallar después de subir los archivos anteriores y Account::Import debe borrarlos. El fallo creíble es omitir discard_imported_records en el rescue de IntegrityError; la prueba observa el servicio real y las filas. No requiere un seam nuevo. El test de traversal conserva su petición HTTP y sus aserciones; su ZIP pasa a contener un cuerpo válido para alcanzar la misma frontera protegida.

## Hallazgos de bloqueo de la primera revisión

Antes de editar las pruebas de esta ronda:
- Contrato: una imagen importada puede quitarse y su cargo se resta. Sólo una carga directa con URL emitida necesita restaurar reserva. Regresión: interpretar quota_upload sin exigir quota_expires_at causa un error en detach. Cobertura: se amplía el round-trip existente; la primera versión sólo leía el consumo y no quitaba el adjunto. Seam: destroy! del adjunto y bytes_used_exact, ambos productivos.
- Contrato: el exportador puede omitir el cuerpo de una carga abandonada sin adjuntos; la importación debe omitir ese blob sin tomar su tamaño como autoridad. Un blob referenciado sin cuerpo debe rechazarse. Regresión: rechazar toda fila sin cuerpo rompe la exportación corriente; omitir una fila referenciada deja referencias sin objeto. Cobertura: se amplía export_with_blobs con una reserva real sin PUT y se conservan los casos negativos de tamaño. Seam: reserve, export y process públicos; no se agrega API para tests.
- RED: base `07361a2104903398180283ddb73b1ee23e8d2e6f`, exportación aislada por git archive con import_test.rb candidato. Mismo entorno Ruby/OSS/SQLite anterior, `mise exec -- bash -c 'cd "$1" && bin/rails test test/models/account/import_test.rb' handy-933-red "$TASK_RED_ROUND2_DIR"`: 21 casos, 143 aserciones, 2 errores productivos, salida 1. Son `invalid xmlschema format: nil` al quitar la imagen importada y `has no storage file` al procesar la carga abandonada, sin errores de entorno.
- GREEN: mismo import_test incluido en el selector anterior más `test/models/storage`: 143 casos, 500 aserciones, cero fallos y errores, salida 0. Las pruebas de cargas directas conservan su cobertura de restauración y limpieza de reservas. Logs locales: `.context/handy-933-round2-red-isolated.log` y `.context/handy-933-round2-green.log`.
- Se cambió el caso de cuerpo ausente a un blob referenciado. Los blobs sin cuerpo y sin referencias se omiten, nunca se guardan con el tamaño declarado. Los callbacks sólo restauran reserva si existe la fecha de una URL PUT emitida; las importaciones no conservan esa fecha del manifiesto.

Suite completa tras resolver los bloqueos, mismo comando y entorno: 1874 casos, 7460 aserciones, cero fallos y errores, seis omisiones; salida 0. La última edición Ruby sólo quitó una línea vacía señalada por RuboCop.

## Revisión de Dédalo tras reanudar

Antes de editar las pruebas:
- Contrato: la cuota cobra originales de imágenes de tarjetas y avatares, y excluye sus variantes y vistas previas. El ciclo export/import y los callbacks de adjuntos deben conservar ese consumo.
- Regresión: marcar todos los blobs importados como quota_upload hace que la reconciliación cobre adjuntos de ActiveStorage::VariantRecord y ActiveStorage::Blob. Al quitar un derivado, un callback tampoco debe restar bytes que nunca se cobraron.
- Cobertura: el round-trip anterior usa texto sin variantes y suma todos los adjuntos como expectativa. Se agrega una frontera real con imagen del fixture, variante procesada y adjunto preview_image. La expectativa usa sólo los tamaños de los originales, medidos desde el fixture. Se incluyen el consumo tras importar y tras quitar derivados, sin copiar el filtro productivo.
- Seam: export, check, process, variant.processed y destroy! de adjuntos son APIs productivas. No se agrega una API de pruebas ni un proveedor simulado.
- Diseño: la exclusión se aplica por tipo de adjunto tanto en reconciliación como en callbacks. Clasificar sólo por blob permitiría que una referencia derivada adicional esconda el cargo de un avatar que usa el mismo blob.
- RED histórico: base `b383163b80c43f9aa92576c13d8d153cd17a6787`, exportación temporal aislada por git archive con el import_test.rb candidato. Mismo entorno Ruby 3.4.8/OSS/SQLite, desde fizzy-custom: `mise exec -- bash -c 'cd "$1" && bin/rails test test/models/account/import_test.rb -n /charge_originals/' handy-933-red "$TASK_DERIVATIVES_RED_DIR"`, precedido por el mismo env del primer RED. Resultado: 1 caso, 4 aserciones, 1 fallo, 0 errores; salida 1. Esperado: 695002 bytes de originales; real: 767338 bytes al cobrar también derivados. Log local: `.context/handy-933-derivatives-red-isolated.log`.
- GREEN: el mismo entorno y selector sobre el arreglo: 1 caso, 8 aserciones, cero fallos y errores; salida 0. El selector completo de importación/almacenamiento pasó: 144 casos y 508 aserciones, sin fallos ni errores.
- Suite final: `mise exec -- bin/rails test` con el entorno anterior, 1889 casos, 7561 aserciones, cero fallos y errores, seis omisiones; salida 0. RuboCop sobre los cuatro archivos Ruby de esta corrección: sin infracciones.

Validación final tras rebase sobre `58e1e4a7e8d883602cb055d0db2c0210b32c5ea1`:
mismo comando completo y entorno, 1912 casos, 7653 aserciones, cero fallos y
cero errores, seis omisiones; salida 0. Se conservaron la validación JSON y
el manejo de errores transitorios de la base. Sólo hubo un conflicto en la
guía, resuelto conservando ambos bloques. `script/check_agents_docs` y
`git diff --check` pasaron.

## Integración después de la aprobación

Rebase sobre `1cde149e8e7b1f71fdcd25479ccb7ac3f5578f00`. La base añadió una
migración con la versión 20261012070000; nuestra migración recibió la versión
única 20261012175410 y los dos esquemas conservan todas las tablas de la base.
El cuerpo de la restricción no cambió. Se reconstruyeron únicamente las bases
SQLite de prueba de este checkout, porque la versión anterior ya constaba como
aplicada y db:schema:load sobre una base existente dejaba la tabla FTS.

Comando de preparación, con el mismo entorno Ruby/OSS anterior:
`RAILS_ENV=test mise exec -- bin/rails db:drop db:create db:schema:load`.
Suite completa: mismo comando y entorno anteriores, 1934 casos, 7839 aserciones,
cero fallos y errores, seis omisiones; salida 0. RuboCop de la migración
renumerada y git diff --check pasaron.

## Integración con las reservas locales de la base nueva

Antes de adaptar las pruebas durante el rebase:
- Contrato: tamaño y checksum se miden antes de insertar blobs; la cuota usa las reservas locales emitidas por Account::Import, sin tomar campos quota_* del manifiesto. Los originales mantienen el cargo hasta borrar el objeto; los derivados no obtienen una reserva que pueda convertirlos en consumo pendiente.
- Regresión: volver a guardar tamaño/checksum declarados, importar autoridad quota_* o emitir reservas para derivados rompe el contrato. Las pruebas siguen observando ZIP real, bytes almacenados, consumo y purga efectiva.
- Cobertura: se conservan los casos de main sobre metadata serializada y reservas de avatar. Los casos de esta tarjeta se adaptan a que main elimina también el archivo ZIP al fallar o completar; el detach retiene el cargo del original hasta el borrado. El round-trip de derivados continúa verificando su exclusión del consumo al retirar adjuntos.
- Seam: se conservan APIs productivas de importación, adjuntos, reservas y limpieza; no se agrega API para pruebas ni se retira un seam.
- Resolución: la metadata portable de presentación de main se conserva como datos de presentación. La autoridad de almacenamiento se limita a tamaño/checksum medidos y filas locales de reserva; quota_* nunca se importa. El purge de main reemplaza la llamada antigua a discard_imported_records, cuya firma cambió.
