# Handy 968: admisión de representaciones de Active Storage

## Problema

`ActiveStorage::Representations::*Controller#show` procesa la representación
en la petición GET. En SaaS el procesador es la celda HotCell, compartida por
todas las cuentas (4 workers, cola de 8). Un fallo permanente
(`Cell::UnprocessableAttachment`) respondía 422 sin guardar el veredicto: cada
GET siguiente volvía a ejecutar el parser. Un miembro podía repetir archivos
costosos y ocupar toda la celda.

## Corrección

`lib/rails_ext/active_storage_representation_admission.rb` reemplaza
`set_representation`. Sólo actúa cuando la representación todavía no está
procesada; una representación ya procesada no consume cupo.

1. **Veredicto negativo.** Un error de `permanent_errors` guarda una entrada en
   `Rails.cache` por 1 día. La clave tiene el id y el checksum del blob, su
   `content_type`, el digest de la variación y la versión del procesador
   (digest de las versiones de gemas de procesamiento y de las clases de
   variante, previsualización y análisis). Mientras la entrada exista, la
   petición responde 422 antes de abrir la celda. Un error transitorio no se
   guarda. SaaS registra `Cell::UnprocessableAttachment`; OSS no registra nada.
2. **Límite por identidad.** 30 procesamientos por minuto (ventana fija). Sin
   identidad, la clave es la IP del cliente.
3. **Concurrencia por cuenta.** 2 procesamientos a la vez por cuenta del blob.
   Cada uno toma una fila de `storage_representation_slots` (índice único
   `account_id, position`) que vence en 3 minutos (más que el timeout de 135 s
   de la celda), y la borra por id en `ensure`. Un rechazo responde 429 con
   `Retry-After`. Las escrituras usan el rol de escritura: un GET puede ir a la
   réplica.

Ronda 1 del gate: la primera versión guardaba los slots en `Rails.cache`. En
MySQL, `write(unless_exist:)` de Solid Cache hace `SELECT … FOR UPDATE` y un
upsert; si la clave no existe, nada bloquea y dos peticiones reciben `true`.
La liberación leía y borraba por separado. Por eso los slots son filas: el
INSERT con índice único es exclusivo en MySQL y SQLite, y el DELETE por id sólo
borra la fila propia. Los contadores de ritmo y los veredictos siguen en la
caché: una escritura perdida sólo cuesta un intento más.

Ronda 2 del gate: `with_writing_role` sobre `Storage::RepresentationSlot` llama
`connected_to` en un modelo concreto, y Rails lanza `NotImplementedError`
cuando hay réplica (SaaS). Las escrituras usan ahora
`ApplicationRecord.with_writing_role`. Su RED está en la sección RED.

Desviación de la tarjeta: la clave incluye el id del blob además del checksum.
El checksum es MD5 y se pueden fabricar colisiones; sin el id, un archivo
fabricado en una cuenta bloquearía la vista previa de otra cuenta. Repetir el
archivo en un blob nuevo cuesta una carga, que ya tiene cuota propia.

Límite conocido: la versión del procesador no incluye las bibliotecas del
contenedor de la celda (libvips, ffmpeg) si cambian sin cambiar una gema. La
expiración de 1 día limita ese caso.

## Respuestas de autoría

Pruebas: `test/integration/active_storage_representation_admission_test.rb`
(7 casos), `test/models/storage/representation_slot_test.rb` (5 casos:
exclusividad, otra cuenta, liberación, toma de un slot vencido sin que la
liberación tardía borre al nuevo dueño, y réplica configurada) y un caso nuevo en
`saas/test/integration/unprocessable_representation_test.rb`.

1. **Contrato.** Respuesta HTTP de los controladores de representación y número
   de llamadas al procesador (`ActiveStorage::Variation#transform`, la frontera
   hacia vips o HotCell). Dueño: `ActiveStorage::RepresentationAdmission`.
2. **Regresión.** Cada caso falla con una mutación concreta (ver abajo):
   quitar el veredicto, guardar transitorios, quitar la variación o la versión
   de la clave, quitar el límite de concurrencia o no liberar el slot.
3. **Cobertura.** `unprocessable_representation_test.rb` sólo comprobaba un
   GET con 422 y el reporte; `active_storage_authorization_test.rb` comprueba
   autorización antes del parser. Ninguna repetía la petición ni medía cupos.
4. **Seam.** `permanent_errors` tiene un consumidor productivo (SaaS lo
   asigna en `UnprocessableAttachments.install!`). `acquire_slot` y
   `Storage::RepresentationSlot#release` los usa el controlador; la prueba de
   saturación los usa para ocupar los slots, porque una prueba de integración secuencial no puede
   mantener dos peticiones abiertas. `Rails.cache` se sustituye por un
   `MemoryStore` porque el entorno de test usa `:null_store`; producción usa
   Solid Cache, compartido por todos los procesos.

## RED

Repo `fizzy-custom`, base `fb2af95ebcd8317391d7b3c7f715d22f97e81ffb`
(`origin/main`, sin el arreglo). Exportación con `git archive HEAD` a
`../.context/handy-968-red`. La base no tiene la API de admisión, por eso la
prueba RED usa las mismas peticiones sin esa API (veredicto y límite por
identidad). Comando, Ruby 3.4.8 de mise, SQLite, Gemfile OSS:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT -u RUBYLIB \
  -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT -u BUNDLE_GEMFILE \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/integration/active_storage_representation_admission_red_test.rb
```

Resultado: salida 1, 2 casos, 1 fallo y 1 error. El segundo GET de la misma
representación volvió a ejecutar el procesador (`PermanentFailure` en el
segundo `get`). La petición 31 de la misma identidad respondió 302, no 429.

GREEN, mismo entorno, en el árbol con el arreglo:
`bin/rails test test/integration/active_storage_representation_admission_test.rb`
→ 7 casos, 0 fallos.

### RED de la réplica

Commit anterior al arreglo: `e60682d0078fce48b55db13e18aecee3ba183c18`
(«Reserva los cupos de representación con un índice único»). Exportación con
`git archive e60682d0078fce48b55db13e18aecee3ba183c18` a
`../.context/handy-968-red-replica`, más
`test/models/storage/representation_slot_test.rb` de la versión entregada
(SHA-256 `3f954c4266be154437db5219f555b63edfc90b60fb106893945e4f05ccb7e96d`).
Mismo entorno que arriba, desde ese directorio:

```bash
env … SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/models/storage/representation_slot_test.rb
```

Resultado: salida 1, 5 casos, 1 error en «acquires and releases when a replica
is configured»: `NotImplementedError: calling connected_to is only allowed on
ActiveRecord::Base or abstract classes`. Es el defecto real: el cambio de rol
sobre el modelo concreto. GREEN en el árbol entregado: 5 casos, 0 fallos.

### Excepción RED explícita: cupos por cuenta

Casos: «a saturated account is refused while another account is still
served», «a slot is released after processing, also when it fails» y los
casos de exclusividad, otra cuenta, liberación y toma de slot vencido de
`representation_slot_test.rb`.

- **Impedimento.** La base `fb2af95…` no tiene ningún cupo por cuenta: no
  existe un estado que saturar ni que liberar, y una prueba de integración
  secuencial no puede mantener abiertas dos peticiones para ocupar la celda.
  Contra la base, el caso de liberación pasa por construcción y el de
  saturación no puede expresarse sin la API nueva. Es comportamiento nuevo, no
  una regresión de un mecanismo anterior. La primera versión con caché
  (`40ccf1d…`, ronda 1) tenía una carrera sólo con escrituras simultáneas en
  MySQL; SQLite y `MemoryStore` serializan las escrituras, así que no se
  reproduce aquí.
- **Evidencia del incidente.** El hallazgo de la tarjeta (cuatro workers y la
  cola compartidos sin límite por cuenta) y los dos bloqueantes de la ronda 1
  del gate (reserva no exclusiva, liberación no atómica).
- **Contrato aún comprobable.** Con dos cupos ocupados la cuenta recibe 429 y
  otra cuenta recibe servicio; un cupo vuelve a estar libre después de un
  éxito o un fallo; una posición tiene un solo dueño; una liberación tardía no
  borra al nuevo dueño.
- **Riesgo sin probar.** Exclusividad bajo concurrencia real en MySQL; la
  defensa es el índice único, no código de la aplicación.
- **Validación alternativa.** Las mutaciones de la tabla siguiente: cada caso
  falla al quitar el límite, no liberar, quitar la unicidad del índice o
  liberar por posición.

Sensibilidad (mutación temporal del archivo productivo, restaurada con `cmp`):

| Mutación | Caso que falla |
|---|---|
| `acquire_slot` siempre devuelve un slot | cuenta saturada |
| se guarda el veredicto de cualquier error | fallo transitorio |
| clave sin digest de variación | otra variación |
| clave sin versión del procesador | otra versión |
| no se libera el slot | slot liberado; límite por identidad |
| índice `account_id, position` no único (schema SQLite) | posición exclusiva; toma de slot vencido |
| liberación por `account_id, position` en vez de id | toma de slot vencido |

## Lo que no verifiqué

- El bundle SaaS no se instala aquí (`rails-structured-logging` es privado).
  El caso nuevo de `saas/test/integration/unprocessable_representation_test.rb`
  y la carga del engine no se ejecutaron; sólo `ruby -c` y RuboCop.
- No ejecuté MySQL ni Solid Cache. La exclusividad de slots depende del índice
  único, no de la caché. No probé dos peticiones simultáneas reales: SQLite
  serializa escrituras en las pruebas. El contador de ritmo usa `increment`;
  con la clave aún ausente, dos peticiones simultáneas pueden contar una vez
  (exceso acotado al inicio de cada ventana).
- No ejecuté la migración en una base existente; las pruebas cargan
  `db/schema_sqlite.rb`. `db/schema.rb` (MySQL) se editó a mano con el mismo
  formato.
- No medí la celda real bajo carga.
