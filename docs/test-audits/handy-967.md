# Cuota con blobs reutilizados en ActionText: Handy 967

Hallazgo de seguridad (BAJA) sobre la revisión `8ea002d5`. Un embed de
ActionText puede reutilizar un blob. Cada adjunto suma otra vez
`blob.byte_size` al ledger. La guarda de SaaS sólo miraba la cuota anterior
en algunos `create` y no protegía `update`. Un miembro podía repetir un blob
grande, sin subir bytes nuevos, hasta bloquear las cargas de toda la cuenta.

## Política elegida

- El cargo sigue siendo **por adjunto** (`Board::Storage` y la conciliación
  cuentan así). Quitar un embed libera `blob.byte_size` de ese adjunto.
- La decisión pasa al modelo. `Storage::Tracked#save`/`save!` (tarjeta,
  comentario, tablero) abre un `Storage::Mutation` dentro de la transacción
  del guardado. El primer adjunto rastreado que se crea o se borra hace el
  UPDATE de la cuenta y lee el uso exacto (línea base). Al terminar el
  guardado, se rechaza si el uso creció y pasa el límite. Un adjunto creado
  fuera de ese guardado (un rich text guardado solo) abre su propia medición.
- Delta neto: el uso exacto incluye el ledger y las reservas de carga directa
  pendientes. Adjuntar un blob reservado mueve su cargo y suma 0. La medición
  cubre todo el guardado, porque Rails guarda el rich text en `after_update`
  y quita una imagen en `after_save`: una comprobación por adjunto contaba
  todavía la imagen quitada (ronda 2 del gate de Dédalo). Un delta nulo o
  negativo se acepta aunque la cuenta esté al límite.
- Un rechazo lanza `Storage::QuotaExceeded` (subclase de `RecordNotSaved`):
  revierte todo el guardado, sin entradas parciales en el ledger.
  `ApplicationController` responde 403, igual que la guarda rápida de SaaS,
  que se conserva sin cambios.
- La importación usa `insert_all` y la incineración suprime el ledger: ninguna
  pasa por esta comprobación.

Límite conocido: en MySQL con REPEATABLE READ (Fizzy propio sobre MySQL), una
lectura anterior en la misma transacción fija la instantánea. SaaS usa
READ-COMMITTED y SQLite serializa a todos los escritores. Es el mismo patrón
que `lock_storage_account` ya tenía.

## Autoría antes de editar las pruebas

- **Contrato:** ningún adjunto rastreado deja la cuenta por encima de su límite
  cuando la mutación aumenta el uso; el rechazo no deja filas en el ledger ni
  el contenido cambiado; quitar un embed libera sus bytes; una edición con
  delta no positivo y un blob reservado se aceptan al límite.
- **Regresión:** quitar la comprobación (estado de la base), hacerla sólo en el
  controlador o sólo en `create`, leer el saldo antes del lock, o contar la
  reserva pendiente dos veces.
- **Cobertura:** `Storage::NoReuseTest` sólo prueba que la reutilización se
  permite; `AttachmentTrackingTest` sólo las entradas del ledger;
  `UploadReservationConcurrencyTest` sólo la reserva. Ninguna prueba el límite
  al adjuntar. Pruebas nuevas:
  - `test/models/storage/quota_test.rb`: reutilización en tarjeta (create de
    adjunto en update), liberación al quitar, comentario en create y update,
    edición de delta neto cero al límite, cambio de imagen por embed del mismo
    tamaño en un solo guardado, carga reservada al límite.
  - `test/models/storage/quota_concurrency_test.rb`: dos updates concurrentes
    con espacio para uno.
  - `Cards::CommentsControllerTest` «update as JSON rejects a reused embed…»:
    respuesta 403 por la entrada HTTP.
  No se retiran pruebas.
- **Seam:** ninguno sólo para pruebas. Entradas productivas: `update!`/`create!` de
  tarjeta y comentario, `attach`, `PUT` del comentario.
  `Account#storage_bytes_allowed` tiene consumidor productivo (la comprobación).

## Evidencia RED y GREEN

Base del repo: `fb2af95ebcd8317391d7b3c7f715d22f97e81ffb`, con las pruebas
nuevas y sin el arreglo. Ruby 3.4.8 con mise, SQLite, sin SaaS. Desde
`fizzy-custom/`, con las variables de Ruby/Bundler heredadas borradas:

```bash
SAAS=false BUNDLE_GEMFILE=Gemfile CI_PROGRESS_BAR=0 PARALLEL_WORKERS=1 \
  mise exec -- bin/rails test test/models/storage/quota_test.rb \
  test/models/storage/quota_concurrency_test.rb \
  test/controllers/cards/comments_controller_test.rb
```

RED (exit 1, 3 fallos de modelo + 1 de controlador):

- `reusing an embedded blob…`: `ActiveRecord::RecordNotSaved expected but
  nothing was raised` (línea 23).
- `a comment cannot reuse…`: lo mismo (línea 43).
- `concurrent embeds…`: `Expected: [:accepted, :rejected] Actual:
  [:accepted, :accepted]`.
- controlador: `comment.reload.body.to_s changed` (respuesta 200, el embed
  se guardó).

Los casos de delta neto cero y de carga reservada pasan en la base: protegen
el diseño contra una comprobación que no sea neta.

GREEN con el arreglo: `21 runs, 115 assertions, 0 failures, 0 errors`.

### Ronda 2: imagen y descripción en el mismo guardado

El gate de Dédalo encontró un bloqueante en la primera versión, que comprobaba
cada adjunto por separado: con la cuenta al límite, `update!(image: nil,
description: <embed de otro blob del mismo tamaño>)` se rechazaba aunque el
delta neto era cero. Prueba nueva: «an edit at the limit may swap the card
image for an embed of the same size».

RED sobre `3f50b977c665ad66de8bea680c60439798d931ac` (primera versión del
arreglo, rebasada sobre `origin/main`), mismo comando:
`Storage::QuotaExceeded: Storage limit exceeded` en
`app/models/storage/attachment_tracking.rb:38` (exit 1). GREEN con
`Storage::Mutation`: `test/models/storage` y los controladores de tarjetas y
comentarios, `168 runs, 647 assertions, 0 failures, 0 errors`.
