# Límites de expansión al importar un ZIP

## Autoría antes de editar las pruebas

Base productiva del RED: `bd1bc8875c6aec4e15f0f1159f13693073aa460c`. Después se
hizo rebase sobre `91dcbf749` (admisión de cuenta única); la suite se repitió.

- **Contrato:** una importación valida el directorio central antes de extraer:
  número de entradas, bytes por entrada, bytes por JSON, total descomprimido y
  relación de compresión (por entrada mayor de 1 MB y por archivo completo).
  La lectura cuenta los bytes reales y se detiene cuando superan el tamaño
  declarado; una lectura infla como máximo 64 KB comprimidos. La reserva de
  disco usa el total descomprimido validado. Si `process` se detiene por un
  límite, borra los registros y archivos importados y conserva la cuenta y el
  archivo de la importación. Dueños: `ZipFile::Limits`, `ZipFile::Reader`,
  `ZipFile::Reader::IO`, `Account::Import` y los `RecordSet`. Fronteras:
  `Account::Import#check`/`#process` con ZIP reales y Active Storage en disco.
- **Regresión:** confiar en el tamaño declarado (sin contador) escribe más
  bytes de los validados; inflar `length` bytes comprimidos sin tope crea
  cadenas de GB; validar después de leer extrae la bomba; calcular la reserva
  con el tamaño del ZIP subestima un ZIP comprimido; no limpiar deja blobs y
  filas de un import rechazado durante 7 días.
- **Cobertura:** `import_test.rb` cubría conflictos, ZIP inválido y la reserva
  con el tamaño del ZIP, sin bombas, tamaños falsos ni limpieza.
  `zip_file_test.rb` cubría lectura normal. `data_import_job_test.rb` ya cubre
  que `ZipFile::InvalidFileError` es terminal; `LimitExceededError` hereda de
  ella. Las tres pruebas de reserva previas se reescriben: con la validación
  antes de la reserva, un archivo que no es ZIP falla antes y las dejaba vacías.
- **Seam:** no se agrega API para pruebas. `ZipFile::Reader.new(io, limits:)`
  es el punto productivo que usa `Account::Import`. `ZipTestHelper` falsifica
  el tamaño declarado en el directorio central de un ZIP real, porque ZipKit
  no permite escribir un tamaño falso. Mocha observa que no se llama
  `ZipEntry#extractor_from` antes del rechazo.

Casos nuevos o cambiados:

| Archivo | Caso | RED en la base |
|---|---|---|
| `models/account/import_test.rb` | rechaza ZIP pequeño con entrada de expansión extrema sin extraer | sí: extrae |
| `models/account/import_test.rb` | `process` detiene un archivo con tamaño real mayor que el declarado y borra registros y blobs | sí: termina sin error |
| `models/account/import_test.rb` | `check` y `process` reservan espacio con el total descomprimido | sí: no reservan |
| `models/account/import_test.rb` | `check` sigue si no se conoce el espacio libre | pasa en la base (cobertura previa adaptada) |
| `models/zip_file_test.rb` | la lectura se detiene al superar el tamaño declarado | sí: no se detiene |
| `models/zip_file_test.rb` | una lectura infla un trozo acotado | sí: devuelve 2 MB |
| `models/zip_file/limits_test.rb` | entradas, entrada, JSON, total, relación, relación total y exención | excepción RED: clase nueva |

**Excepción RED de `limits_test.rb`:** la clase no existe en la base. Los
umbrales reales (1 000 000 entradas, 1 TB) necesitan GB de entrada para una
prueba de importación. El contrato de relación de compresión sí tiene RED a
nivel de importación. Sensibilidad: con las comprobaciones de entradas y de
total desactivadas, `limits_test.rb` dio 2 fallos (los dos casos esperados);
restaurado, 8 casos verdes.

## Evidencia

Se exportó la base con `git archive` a `.context/handy-782-base` y se copiaron
los tres archivos candidatos, idénticos en ambas ejecuciones:

| Archivo bajo `test/` | SHA-256 |
|---|---|
| `models/account/import_test.rb` | `52cc6a9b3dcc8993809df4cdb6eac967b82b0c5c934fdfb652752cc3587e6022` |
| `models/zip_file_test.rb` | `579eaa11ea2f9a4707952e5c02c237595772cafe67309cf7b384e0938379009a` |
| `test_helpers/zip_test_helper.rb` | `8fe7961a11ad51a0e0d20ecc33531e8d265dd32bdda62a3a6cee12a19ed4dda9` |

Comando, desde el checkout correspondiente, con Ruby 3.4.8 de mise y SQLite:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ./bin/rails test test/models/zip_file_test.rb test/models/account/import_test.rb
```

RED en la base: salida 1; 32 casos, 6 fallos, cero errores. Las dos reservas
reciben `IntegrityError` en vez de `InsufficientStorageSpaceError`; la bomba
llama a `extractor_from`; el tamaño falso termina sin error en `process` y en
el lector; la lectura acotada devuelve 2 097 152 bytes.
Evidencia local: `.context/handy-782-red.log`.

GREEN con el arreglo: los mismos archivos más `test/models/zip_file` y
`test/jobs/account/data_import_job_test.rb`, 43 casos sin fallos. Suite
completa tras el rebase (`bin/rails test`, SQLite, paralela): 1827 casos, 0 fallos, 0
errores, 6 omisiones previas. RuboCop sin ofensas en los archivos tocados.

No verificado: S3 real (la lectura por `RemoteIO` usa el mismo `Reader::IO`),
MySQL y archivos de cientos de GB.
