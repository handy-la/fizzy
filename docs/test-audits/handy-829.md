# Lectura acotada del directorio central de ZIP

## Autoría antes de editar pruebas

Base productiva: `7e87d1aebcf44d0d631d4e2d71297b4d81ae5aac`.

- **Contrato:** `ZipFile::Reader`, usado por `Account::Import` con sus límites,
  rechaza el número de entradas y los bytes del directorio central antes de
  construir entradas. Lee sólo los bytes declarados del directorio. El EOCD
  ZIP64 tampoco permite una lectura de tamaño arbitrario. Fronteras: ZIP reales
  modificados, IO local y `ZipFile::RemoteIO` con respuestas HTTP por rango.
- **Regresión:** validar después de `read_zip_structure` construye entradas
  antes de rechazar; `io.read` sin longitud descarga el resto del archivo;
  confiar en el tamaño ZIP64 permite otra lectura arbitraria.
- **Cobertura:** `ZipFile::LimitsTest#rejects too many entries` sólo comprobaba
  el error final; se amplía para observar que no se parsea ninguna entrada.
  `ZipFileTest` comprueba lectura normal y extracción acotada, pero no el
  directorio, los rangos HTTP ni ZIP64. Los nuevos casos cubren estos riesgos.
- **Seam:** no se agrega API productiva para pruebas. Se usa el constructor
  productivo del lector. Mocha observa `read_cdir_entry`; `RecordingIO` registra
  longitudes sin cambiar la lectura de `StringIO`.
  WebMock devuelve bytes de un ZIP real a `RemoteIO`, sin simular el parser.
  Los ayudantes de prueba alteran campos del formato ZIP y agregan el EOCD ZIP64.

## Evidencia

Se exportó la base con `git archive` a `.context/handy-829-base`. Se copiaron
las mismas pruebas candidatas antes del RED y del GREEN:

| Archivo bajo `test/models/zip_file/` | SHA-256 |
|---|---|
| `structure_test.rb` | `94e22584976838da1419b814f0fada20d3ef970279b17082077dabe920da18ed` |
| `limits_test.rb` | `c9be209f7691640d42986b67b2c850809cbd5c425c27cc71f5fc7d1b352880d4` |

Comando desde cada checkout, Ruby 3.4.8 de mise y SQLite:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ./bin/rails test test/models/zip_file/structure_test.rb test/models/zip_file/limits_test.rb
```

**RED:** salida 1, 19 casos, 10 fallos, cero errores. En ambos formatos se
llama a `read_cdir_entry` antes de rechazar el conteo o el tamaño. Los rangos
HTTP incluyen el final completo, sin una lectura del directorio exacto. Se
ignora el directorio truncado, se lee hasta EOF al falsear su inicio y se
solicita 1 TiB al falsear el tamaño del EOCD ZIP64. Los dos casos de ubicación
fuera del archivo ya pasan en la base: conservan la defensa al cambiar el parser.
Evidencia local: `.context/handy-829-red.log`.

**GREEN:** mismo comando, salida 0; 19 casos, 72 aserciones, sin fallos ni
errores. Se amplió la ejecución a `test/models/zip_file_test.rb`,
`test/models/zip_file`, `test/models/account/import_test.rb` y
`test/jobs/account/data_import_job_test.rb`: 54 casos, 187 aserciones, sin
fallos ni errores. La importación normal conserva su cobertura de integración.
Evidencia local: `.context/handy-829-green.log`.

Suite completa: mismo entorno con `PARALLEL_WORKERS=4`, comando
`mise exec -- ./bin/rails test`: salida 0, 1865 casos, 7372 aserciones,
cero fallos, cero errores y seis omisiones previas.

RuboCop sobre los cinco archivos Ruby modificados: sin ofensas.

## Política y límites

El máximo predeterminado del directorio es 256 MiB. Acota la asignación que
depende del archivo y deja espacio para un millón de entradas con nombres y
campos extra habituales. Se puede ajustar con `max_central_directory_size`.
La búsqueda del EOCD lee como máximo 65 557 bytes; el EOCD ZIP64 se lee en
campos fijos, sin cargar su sector extensible. La lectura del directorio usa
su tamaño exacto y comprueba que quede antes de las cabeceras finales.
Los tamaños declarados incorrectos ya no reciben la recuperación permisiva
de ZipKit que leía hasta EOF.

No verificado: S3 real (se comprobaron los rangos HTTP del `RemoteIO`
productivo con WebMock), MySQL, modo SaaS y archivos de cientos de GB.
