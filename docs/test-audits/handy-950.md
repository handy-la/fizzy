# Avatares importados en el recálculo de cuota

## Autoría antes de editar pruebas

Base del repo: `d1790a8af586ca4ca33152e08fb2e96fde0d6cb6`.

- **Contrato:** después de importar una cuenta, el avatar de un usuario
  importado cuenta en el saldo exacto de la cuenta. El recálculo de la
  importación lo incluye y quitar el avatar lo descuenta. La importación no
  crea reservas de subida ni conserva `quota_identity_id` o
  `quota_expires_at` del ZIP, tampoco al quitar el avatar. Dueños:
  `AttachmentRecordSet`, `Account::Storage` y `Storage::AttachmentTracking`.
  Frontera: export real, ZIP, `Account::Import#process`, filas persistidas,
  callbacks de adjuntos y saldo exacto.
- **Regresión:** Handy #931 quita todo `quota_*` al importar.
  `Account::Storage#untracked_direct_upload_bytes` sólo cuenta un adjunto
  fuera de `Card` y `ActionText::RichText` con `quota_upload`. El avatar
  importado queda con saldo cero después de `reconcile_account_storage`.
  Restaurar `quota_*` desde el ZIP para corregirlo volvería a dar autoridad
  a datos del archivo.
- **Cobertura:** `ImportTest#export and import round-trip preserves blobs and
  attachments` comprueba el contenido del blob, no el saldo.
  `BlobRecordSetTest#import rebuilds portable metadata without quota
  authority` comprueba metadata y reservas con un adjunto de `Card`, que el
  ledger cuenta por tipo. `UploadReservationTest#untracked avatar remains
  charged after attachment and reconciliation` cubre un avatar de carga
  directa en la cuenta de origen, no uno importado. Ninguna prueba recalcula
  el saldo de un avatar después de una importación.
- **Seam:** ninguno nuevo. Se usan export, importación, recálculo, adjuntos y
  almacenamiento Disk reales. No se sustituye la decisión de cuota.

Antes de agregar `imported avatar is charged by reconciliation and released on
purge without a reservation`: la prueba exporta la cuenta real con un avatar
de `moon.jpg` (12.794 bytes). Su blob de origen lleva `quota_upload`,
`quota_identity_id` y `quota_expires_at` como datos adulterados del ZIP. La
prueba borra del origen blobs, adjuntos y `VariantRecord` antes de importar,
porque el export incluye la miniatura del avatar y su fila chocaría con la de
origen. Comprueba el saldo exacto después de `process`, otro recálculo, el
borrado del avatar y un recálculo final, sin reservas nuevas.

## RED histórico y GREEN

Desde `fizzy-custom/`, Ruby 3.4.8 de mise, OSS y SQLite, en la base
`d1790a8af586ca4ca33152e08fb2e96fde0d6cb6` con sólo la prueba nueva aplicada.
SHA-256 de `test/models/account/import_test.rb` en RED y GREEN:
`ad50982f1ccc4d81caf954f46a61f902010807e68f7c59ba75795c3b63ee87fd`.

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/models/account/import_test.rb -n "/imported avatar/"
```

RED: salida 1, un caso, nueve aserciones, un fallo: `Expected 0 to be >=
12794.` La importación termina, no crea reservas ni conserva `quota_*`, pero
el saldo y el recálculo dan cero bytes.

GREEN con el arreglo: salida 0, un caso, 16 aserciones. El saldo coincide con
el recálculo, se mantiene tras otro recálculo y baja 12.794 bytes al quitar el
avatar, sin reservas nuevas.

## Decisiones

- El servidor, no el ZIP, decide el cargo: `AttachmentRecordSet` marca
  `quota_upload` en los blobs de adjuntos importados de `User`, después de
  insertar el lote. Se reutiliza la marca existente para que el recálculo,
  el cargo al adjuntar y el descuento al quitar sigan una sola regla.
- La marca no da autoridad de reserva: el borrado busca sólo filas de
  `Storage::UploadReservation`, y la importación no crea ninguna. No se
  restauran `quota_identity_id` ni `quota_expires_at`.
- Sólo se marca `User`. `Card` y `ActionText::RichText` ya cuentan por tipo.
  `Export` y `Account::Import` no se exportan. Las miniaturas
  (`ActiveStorage::VariantRecord`) tampoco cuentan en una carga directa.
- Un avatar que en origen se subió por formulario no tenía cargo; importado
  sí lo tiene. Es el comportamiento pedido por la tarjeta: los bytes del
  avatar importado ocupan almacenamiento en la cuenta de destino.
- No hay efecto visual, archivos de revisión ni pasos manuales.

## Qué no pude comprobar

No ejecuté MySQL, el entorno SaaS ni S3. No verifiqué producción ni reparé
cuentas importadas antes de este cambio: su saldo se corrige sólo si se
vuelven a importar.

## Validación final del lote

Desde `fizzy-custom/`, mismo entorno OSS/SQLite y `PARALLEL_WORKERS=4`:
`mise exec -- bin/rails test`, salida 0: **1.996 casos, 8.210 aserciones,
cero fallos, cero errores y seis omisiones**. `bin/rubocop -f simple` sobre
los dos archivos Ruby modificados: cero infracciones. `git diff --check`:
salida 0. `dedalo.toml` no exige un job CI para `fizzy-custom`.
