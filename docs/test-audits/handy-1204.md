# Handy 1204: tamaño y cuota del avatar de usuario

## Problema

`UsersController#update` (y `Users::JoinsController`) adjunta el avatar desde
un formulario multipart. Esa ruta no pasa por `Storage::UploadReservation`.
`has_one_attached :avatar` tiene una variante `process: :immediately`, así que
Active Storage analiza la imagen en su `before_validation`, antes de cualquier
validación del modelo, sin límite de bytes. El blob tampoco se cobraba al
ledger: `User` no es un registro rastreado y el blob no llevaba
`quota_upload`.

## Corrección

`User::Avatar`:

1. `MAX_AVATAR_BYTES = 10.megabytes`. `reject_oversized_avatar` es un
   `before_validation` con `prepend: true`: corre antes del análisis de
   `has_one_attached`. Agrega el error y aborta; el guardado no ocurre, y la
   subida y la variante (en `after_commit`) tampoco.
2. `before_save` marca el blob nuevo con `quota_upload`. Así
   `Storage::AttachmentTracking` registra `attach` y `detach`, y la
   reconciliación (`untracked_direct_upload_bytes`) cuenta el mismo blob.
3. `User#save` y `User#save!` envuelven el guardado con `Storage::Mutation.wrap`
   cuando hay un avatar nuevo, como `Storage::Tracked`. El mismo `before_save`
   llama a `start`: bloquea la cuenta y lee `bytes_used_exact`. `verify!` corre
   cuando termina todo el guardado, después del `after_save` de
   `has_one_attached` que crea el adjunto. Si el avatar pasa `storage_limit`,
   `Storage::QuotaExceeded` revierte la transacción (el controlador responde
   403, como en tarjetas). Un blob de subida directa ya reservado conserva su
   cargo: al adjuntarlo, la reserva deja de estar pendiente.

## Pruebas (cuatro respuestas)

- **Contrato:** un avatar mayor que el límite se rechaza antes del analizador
  y no deja blob ni variante; uno válido sube `bytes_used_exact` y respeta
  `storage_limit`; dos cargas paralelas no superan la cuota. Dueño:
  `User::Avatar`. Frontera: `User#update` y `PUT /users/:id`.
- **Regresión:** quitar el guard o declararlo sin `prepend` ejecuta el
  analizador; quitar `quota_upload` deja el ledger igual; quitar el bloqueo
  de `Storage::Mutation#start` deja pasar las dos cargas.
- **Cobertura:** las pruebas de dimensiones de `avatar_test.rb` y
  `users_controller_test.rb` sólo cubren píxeles y tipo; `Storage::QuotaTest`
  y `QuotaConcurrencyTest` sólo cubren registros rastreados.
- **Seam:** ninguno; se usa la ruta pública de actualización.

Casos: `test/models/user/avatar_test.rb` (tres casos nuevos),
`test/controllers/users_controller_test.rb` («over the byte limit stores
nothing») y `test/models/user/avatar_quota_concurrency_test.rb`.

## RED

Base exacta `b9e10f1f8b0c874085845e8f87c50f7bb95299d8`, sin ningún cambio
productivo: exportación aislada con `git archive` en un directorio temporal,
con los tres archivos de prueba de este lote copiados encima y una base de
test nueva (`RAILS_ENV=test bin/rails db:drop db:create db:schema:load`).
Comando, en esa exportación, con las variables de Ruby/Bundler heredadas
borradas: `SAAS=false BUNDLE_GEMFILE=Gemfile mise exec -- bin/rails test
test/models/user/avatar_test.rb test/models/user/avatar_quota_concurrency_test.rb
test/controllers/users_controller_test.rb`.

Resultado: `35 tests, 161 assertions, 3 failures, 2 errors`, código de
salida 1. Los tres fallos son RED válido del contrato:

- cobro: `Expected: 347501 / Actual: 0` en `bytes_used_exact`;
- cuota: `Storage::QuotaExceeded expected but nothing was raised.`;
- concurrencia: `Expected: [:accepted, :rejected] / Actual: [:accepted, :accepted]`.

### Excepción RED explícita: las dos pruebas de tamaño

- **Impedimento:** «rejects an avatar over the byte limit before analyzing it»
  y «update with an avatar over the byte limit stores nothing» citan
  `User::Avatar::MAX_AVATAR_BYTES`, que no existe en la base. Allí fallan con
  `NameError: uninitialized constant User::Avatar::MAX_AVATAR_BYTES`, que no es
  RED válido.
- **Contrato comprobable:** el analizador no corre y no queda blob ni variante
  para un archivo mayor que el límite.
- **Validación alternativa:** la misma base con un único cambio temporal, la
  constante `MAX_AVATAR_BYTES = 10.megabytes` sin conducta. Mismo comando:
  el modelo falla con `expected never, invoked once:
  ...ImageAnalyzer::Vips.metadata()`, y el controlador con
  `ActiveStorage::Blob.count didn't change by 0, but by 2` (original y
  miniatura), código de salida 1.
- **Riesgo sin probar:** ninguno del contrato; sólo que esa variante no es la
  base histórica literal.

GREEN con el arreglo: los mismos archivos y la suite completa
`SAAS=false BUNDLE_GEMFILE=Gemfile bin/rails test` (2185 pruebas, 0 fallos,
código de salida 0).

## Ronda 1 de `bin/signoff`

El revisor afirmó que los `after_save` corren en orden inverso y que `verify!`
corría antes del cobro. Una traza mostró `START → ENTRY attach → VERIFY` y,
al declarar el `after_save` antes de `has_one_attached`, fallaron las pruebas
de cuota y concurrencia. La ronda 2 repitió el veredicto por caché. Para no
depender del orden de callbacks, la verificación pasó a envolver `save`.
Sensibilidad del diseño final: sin `start` fallan las mismas dos pruebas.

## No verificado

La variante SaaS (`Gemfile.saas`, MySQL) no corrió en este worktree. El
avatar de `Identity` (global, sin cuenta) queda fuera de esta tarjeta.
