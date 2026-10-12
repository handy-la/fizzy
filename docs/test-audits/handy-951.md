# Costo de las reservas pendientes con muchos adjuntos

Origen: hallazgo de handy-931. Desde handy-931, `Storage::UploadReservation`
conserva una fila de emisión por cada carga directa adjunta. El scope `pending`
excluye esas filas con `blob_id NOT IN (SELECT blob_id FROM
active_storage_attachments)`. `Account::Storage#bytes_used`, `#bytes_used_exact`,
los cupos de `reserve` (`in_flight`) y la limpieza leen ese scope.

Base medida: `fizzy-custom` `0de30b69d7035f090ab1937f663b30f5daf7a7a8`, que
contiene `d1790a8af` (handy-931). Este lote no cambia código ni pruebas.

## Método

Un script de `rails runner` (`RAILS_ENV=test`, Ruby 3.4.8 de mise, OSS, SQLite
3.53.2 de la gema) crea una base SQLite temporal y vacía. Carga
`db/schema_sqlite.rb`, inserta filas con `insert_all!` y ejecuta `ANALYZE`. No
usa la base de pruebas ni datos privados. El caso más desfavorable es que cada
adjunto sea una carga directa: cada adjunto tiene su fila de emisión. Los
adjuntos se reparten entre la cuenta medida (N filas) y otras 999 cuentas. La
cuenta medida tiene además cinco reservas pendientes de 7 bytes.

Cada consulta se ejecuta una vez para calentar y después 15 veces. La tabla
muestra la mediana y el máximo de `Benchmark.realtime`. Equipo: AMD Ryzen 9
9950X, disco local. El script queda como evidencia local
(`../.context/handy-951-measure.rb`); esta descripción permite repetir la carga.

| Adjuntos en total | Filas retenidas de la cuenta | `pending.sum(:byte_size)` | `in_flight.count` | Otra cuenta (≈900 filas) |
|---:|---:|---:|---:|---:|
| 10 000 | 1 000 | 0,27 ms (máx. 0,47) | 0,35 ms | 0,18 ms |
| 100 000 | 10 000 | 1,99 ms (máx. 2,54) | 1,89 ms | 0,17 ms |
| 1 000 000 | 100 000 | 22,99 ms (máx. 24,55) | 22,28 ms | 0,57 ms |

Todos los resultados son exactos: 35 bytes pendientes y 5 cargas en curso.
El plan es igual en las tres escalas:

```
SEARCH storage_upload_reservations USING INDEX index_storage_upload_reservations_on_account_id (account_id=?)
USING INDEX index_active_storage_attachments_on_blob_id FOR IN-OPERATOR
```

SQLite no materializa la tabla global de adjuntos. Por cada fila de la cuenta,
consulta el índice de `blob_id`. El costo crece en línea recta con las filas
retenidas de **esa** cuenta, unos 0,23 µs por fila. Los adjuntos de otras
cuentas casi no influyen. `in_flight` tiene el mismo costo: el filtro de
`created_at` se aplica después de leer todas las filas de la cuenta.

En una admisión (`reserve`) hay tres lecturas de este tipo bajo el lock de
escritura de SQLite: los cupos por identidad y por cuenta, y el saldo exacto.
Con 100 000 cargas directas adjuntas en una cuenta, son unos 70 ms con el lock
tomado. Con 10 000, unos 6 ms.

## Escala real

El 2026-10-12 se contaron, en modo sólo lectura (`sqlite3 "file:…?mode=ro"`),
las filas del Fizzy local de Dédalo, el que usa este fork: una cuenta, 1 247
adjuntos y 1 247 blobs. Sólo se leyeron conteos agregados. Con esa escala, la
consulta cuesta del orden de 0,3 ms.

## Por qué no se acota con una marca en la fila

La única forma de que el índice limite la lectura a las filas pendientes es
guardar en la fila si su blob está adjunto: un booleano mantenido por
`Storage::AttachmentTracking` y un índice `[account_id, attached]`. La marca
dependería de los callbacks de `ActiveStorage::Attachment`, y Rails quita
adjuntos sin ellos: `Attached::One#detach` llama a `attachment.delete`, y
`detach` de `has_many_attached` usa `delete_all`.

Se comprobó con una prueba temporal, fuera del lote, contra esta base: después
de `cards(:logo).image.detach` el blob queda sin adjuntos, el ledger conserva
sólo `attach`, la reserva no cambia su vencimiento y `pending` la vuelve a
incluir. Con la marca, esa fila quedaría como «adjunta» sin adjuntos: el saldo
bajaría (se pierde la exactitud) y la limpieza dejaría de verla (blob y objeto
retenidos para siempre). `NOT IN` deriva el estado de los adjuntos reales y no
tiene ese problema. Un barrido que corrija la marca volvería a recorrer todas
las filas y sólo acortaría el desfase.

## Decisión

No se cambia la consulta. El costo es lineal, usa índices en ambas tablas y,
a la escala real, cuesta menos de un milisegundo. Acotarla con una marca
cambiaría un costo medido y pequeño por una pérdida de exactitud que no se
puede detectar. Se conservan la fila de emisión, el saldo exacto, los cupos,
los locks y la limpieza.

Revisar esta decisión cuando una cuenta se acerque a 100 000 cargas directas
adjuntas (unos 23 ms por lectura y unos 70 ms por admisión con el lock tomado).
Cualquier diseño acotado debe registrar también los borrados sin callbacks
(`delete`, `delete_all`), no sólo `destroy`.

## Lo que no se verificó

MySQL y el modo SaaS: no hay un servidor MySQL disponible en esta máquina.
MySQL 8 suele convertir `NOT IN (subconsulta)` sobre una columna `NOT NULL` en
un antijoin con el índice de `blob_id`, pero no se midió. Tampoco se midió la
contención real de varias cargas simultáneas ni el disco del servidor de
producción.
