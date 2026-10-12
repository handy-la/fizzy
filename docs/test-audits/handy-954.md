# Purga de importaciones fallidas: lock corto y barrido aislado

Origen: hallazgo no bloqueante de Handy #943. Base del repo:
`62be5cb60753d317a399dde72ba36bf9556d875c` (incluye Handy #943).

## Cambio

- `Account::Import#purge_failed_files` borra los objetos de almacenamiento
  (blobs importados con `Manifest#delete_files` y el ZIP) **antes** de tomar
  el lock de cuenta (`Storage::UploadReservation.serialize_account`). Las
  filas, las claves, las reservas y la admisión no cambian hasta que esos
  borrados terminan. Si un borrado falla, la excepción sale antes del lock y
  todo queda para reintentar.
- Bajo el lock, `delete_files(except:)` sólo borra objetos de blobs creados
  después de la primera pasada; normalmente es una consulta sin red. Después
  se borran filas, reservas, el ZIP y se cierra la admisión, como antes.
- `FileRecordSet#discard` ya no borra objetos: `Manifest#discard_records`
  sólo borra filas. El único consumidor es la purga de importaciones.
- `Account::Import.cleanup` aísla cada importación fallida: reporta el error
  con `Rails.error.report` y sigue con las demás, con el borrado de
  importaciones vencidas y con el de admisiones antiguas. Una importación cuya
  purga falló en esa ejecución no entra al borrado de vencidas: destruirla
  perdería la fila que permite reintentar y dejaría blobs huérfanos (hallazgo
  de la ronda 1 de `bin/signoff`).
- `mark_completed` sigue borrando el ZIP bajo el lock (`purge_archive`); no
  está en el alcance de esta tarjeta.

## Autoría antes de editar pruebas

### `ImportPurgeConcurrencyTest#another account writer commits while a failed import deletes storage objects`

- **Contrato:** mientras la purga de una importación fallida llama al servicio
  de almacenamiento, otro escritor de la misma cuenta puede tomar el lock de
  cuenta y confirmar su transacción. Dueño: `Account::Import#purge_failed_files`.
  Frontera: servicio Disk real, dos conexiones reales a la base y el lock de
  `Storage::UploadReservation.serialize_account`.
- **Regresión:** mover cualquier llamada `delete` del servicio dentro de
  `serialize_account` (el código de la base) deja al segundo escritor
  bloqueado hasta que termina la red.
- **Cobertura:** `ImportTest#failed object deletion preserves the ZIP and quota
  until cleanup succeeds` comprueba el orden objeto→cargo, no el lock.
  `ImportAdmissionConcurrencyTest` comprueba reservas concurrentes, no la
  purga. Ninguna prueba observa otro escritor durante el borrado.
- **Seam:** ninguno nuevo. La prueba reemplaza `delete` del servicio Disk por
  una envoltura que llama al original y, antes, lanza un hilo con su propia
  conexión que toma el lock de cuenta. Espera 2 s; si no termina, registra
  `:blocked`. No usa transacciones de prueba porque el lock debe ser real.

### `ImportTest#cleanup purges the next failed import when one object deletion fails`

- **Contrato:** un fallo de borrado en una importación fallida no detiene el
  barrido horario. La importación con fallo, aunque ya esté vencida, sigue
  existiendo y conserva ZIP, fila del blob, cargo y admisión abierta; la siguiente se purga; el borrado de admisiones
  terminadas hace más de 24 horas también corre. Dueño:
  `Account::Import.cleanup`. Frontera: almacenamiento Disk, filas y saldo
  exacto de la cuenta.
- **Regresión:** `find_each(&:purge_failed_files)` sin rescate por elemento
  (código de la base) propaga el `IOError` y deja sin purgar la importación
  siguiente y sin borrar la admisión antigua. Un rescate sin excluir la
  importación de `expired` la destruye en el mismo barrido.
- **Cobertura:** `failed object deletion preserves the ZIP and quota until
  cleanup succeeds` usa una sola importación y espera la excepción en
  `mark_as_failed`; no cubre el barrido con varias importaciones.
  `ImportAdmissionTest#finished attempts keep the rolling rate limit...` no
  inyecta fallos.
- **Seam:** ninguno nuevo. Envoltura temporal de `delete` del servicio Disk
  que falla sólo para la clave del primer ZIP y llama al original para las
  demás; se retira en `ensure`. Las importaciones se ordenan por id para que
  el fallo ocurra en la primera que procesa `find_each`.

## Evidencia RED → GREEN

Directorio `fizzy-custom/`, SQLite, comando:

```
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u BUNDLE_GEMFILE -u BUNDLE_PATH \
  SAAS=false mise exec -- bin/rails test \
  test/models/account/import_purge_concurrency_test.rb test/models/account/import_test.rb \
  -n "/another account writer|next failed import/"
```

- **RED** sobre `62be5cb60` con las dos pruebas nuevas y sin el arreglo:
  salida 1, `2 tests, 1 assertions, 1 failures, 1 errors`.
  - Concurrencia: `Expected: [:written]  Actual: [:blocked]`.
  - Barrido: `IOError: storage unavailable` desde
    `Account::Import#purge_archive` ← `purge_failed_files` ←
    `Account::Import.cleanup`.
- **GREEN** con el arreglo: salida 0, `2 tests, 13 assertions, 0 failures,
  0 errors`.

- **Sensibilidad, ronda 2 de revisión:** con un cambio temporal controlado que
  devuelve `expired.each(&:cleanup)` (código de la ronda 1, rescate sin
  exclusión), la prueba del barrido falla: `1 tests, 2 assertions, 1 failures`,
  mensaje `an expired import whose purge failed must stay for the next sweep`.
  Con la exclusión: `import_purge_concurrency_test`, `import_test`,
  `import_admission_test`, `import_admission_concurrency_test` y
  `test/models/account/data_transfer` dan `81 tests, 285 assertions, 0 failures`.

## Suite y estilo

| Comando (`fizzy-custom/`, variables Ruby limpias, `mise exec`) | Resultado |
|---|---|
| `SAAS=false PARALLEL_WORKERS=4 bin/rails test` | Salida 0; 2.016 casos, 8.390 aserciones, 0 fallos, 6 omisiones (después de la ronda 2) |
| `bin/rubocop -f simple` sobre los 5 archivos Ruby modificados | Salida 0, sin infracciones |

## No verificado

- MySQL: la prueba de concurrencia corre en SQLite. En MySQL el UPDATE de
  cuenta toma un lock de fila; el contrato es el mismo, pero no lo ejecuté.
- S3: el borrado de un objeto que ya no existe es idempotente en Disk y S3
  según ActiveStorage; un reintento después de un fallo de base de datos
  vuelve a borrar objetos ya borrados. Sólo lo comprobé con Disk.
