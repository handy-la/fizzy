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
   Cada uno toma un slot con `write(unless_exist: true)` de 3 minutos (más que
   el timeout de 135 s de la celda), y lo libera en `ensure`. Un rechazo
   responde 429 con `Retry-After`.

Desviación de la tarjeta: la clave incluye el id del blob además del checksum.
El checksum es MD5 y se pueden fabricar colisiones; sin el id, un archivo
fabricado en una cuenta bloquearía la vista previa de otra cuenta. Repetir el
archivo en un blob nuevo cuesta una carga, que ya tiene cuota propia.

Límite conocido: la versión del procesador no incluye las bibliotecas del
contenedor de la celda (libvips, ffmpeg) si cambian sin cambiar una gema. La
expiración de 1 día limita ese caso.

## Respuestas de autoría

Pruebas: `test/integration/active_storage_representation_admission_test.rb`
(7 casos) y un caso nuevo en
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
   `release_slot` los usa el controlador; la prueba de saturación los usa
   para ocupar los slots, porque una prueba de integración secuencial no puede
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

Sensibilidad (mutación temporal del archivo productivo, restaurada con `cmp`):

| Mutación | Caso que falla |
|---|---|
| `acquire_slot` siempre devuelve un slot | cuenta saturada |
| se guarda el veredicto de cualquier error | fallo transitorio |
| clave sin digest de variación | otra variación |
| clave sin versión del procesador | otra versión |
| no se libera el slot | slot liberado; límite por identidad |

## Lo que no verifiqué

- El bundle SaaS no se instala aquí (`rails-structured-logging` es privado).
  El caso nuevo de `saas/test/integration/unprocessable_representation_test.rb`
  y la carga del engine no se ejecutaron; sólo `ruby -c` y RuboCop.
- No ejecuté Solid Cache ni MySQL; los slots y contadores dependen de
  `write(unless_exist:)` e `increment` atómicos, que Solid Cache implementa con
  bloqueo de fila (`entry_lock_and_write`).
- No medí la celda real bajo carga.
