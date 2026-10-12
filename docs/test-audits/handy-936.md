# Importaciones ZIP con índice acotado

## Autoría antes de editar pruebas

Base productiva: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.

- **Contrato:** la política productiva de `Account::Import` rechaza ZIP válidos
  con más de 50 000 entradas o directorios mayores de 16 MiB antes de crear
  entradas. El endpoint admite sólo una importación pendiente o en curso por
  identidad global, sin crear otra cuenta, adjunto ni trabajo al rechazar.
  Una importación terminada libera el cupo; otras identidades son independientes.
- **Regresión:** volver al millón de entradas o a 256 MiB acepta el ZIP de
  límite + 1; consultar cupos por cuenta permite eludirlos creando otra cuenta;
  consultar después de Signup deja recursos y trabajos al rechazar.
- **Cobertura:** `ZipFile::StructureTest` ya protege el orden con límites
  artificiales de diez entradas, pero no la política de importación. Se amplía
  allí la cobertura con un ZIP válido en el límite productivo + 1 y con el
  límite productivo de bytes. `Account::ImportsControllerTest` sólo prueba una
  petición permitida y el modo de cuenta única. Se agregan casos de admisión,
  liberación y aislamiento global; no se retira cobertura previa.
- **Seam:** constructor productivo del lector y peticiones HTTP reales.
  `RecordingIO` y Mocha observan lecturas y creación de entradas, sin reemplazar
  su contenido. No se agrega API exclusiva de pruebas. La operación de admisión
  será el acceso productivo del controlador.

## Evidencia

Se exportó el SHA base con `git archive` a `.context/handy-936-base` y se
copiaron las pruebas candidatas sin cambiar el código productivo. Ruby 3.4.8,
Linux x86_64, SQLite, modo propio. Las variables Ruby/Bundler heredadas se
eliminaron con `env -u` como indica `CLAUDE.md`.

Comando desde la exportación para RED y desde `fizzy-custom/` para GREEN:

```sh
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/models/zip_file/structure_test.rb \
    test/controllers/account/imports_controller_test.rb
```

- RED: salida 1, 20 casos, cuatro fallos, cero errores. El ZIP válido de
  50 001 entradas llama al parser; el directorio válido de más de 16 MiB también
  llama al parser. Las peticiones de una identidad con importación pendiente o
  en curso crean trabajos en vez de rechazarse. Log local:
  `.context/handy-936-red-export.log`.
- GREEN: mismo comando, salida 0, 20 casos, 128 aserciones, sin fallos.
  Log local: `.context/handy-936-green.log`.
- Carrera: mismo entorno, cambiando los archivos seleccionados por
  `test/controllers/account/import_admission_test.rb`. RED: salida 1, un caso,
  `[302, 302]` en lugar de `[302, 429]`. GREEN: salida 0, un caso, cinco
  aserciones. Logs locales: `.context/handy-936-race-{red,green}.log`.

SHA-256 de los archivos candidatos idénticos en RED y GREEN:

| Prueba | SHA-256 |
|---|---|
| `structure_test.rb` | `0bd3a4db17af33e5632133934183b2524c3f1591dc3424cc720c2159d05424db` |
| `imports_controller_test.rb` | `52ba10bc3d9438919317c68cedc70febc3c5e4ade347ae06cb65d212060f4491` |
| `import_admission_test.rb` | `9d80e1380dd2e562e1098cbc8a7db4c6ae9400da59238f374631bc21be7c4f72` |

## Autoría del caso de carrera

- **Contrato:** dos peticiones simultáneas de una identidad no crean dos cuentas
  de importación. Frontera HTTP y base SQLite real, con dos sesiones y conexiones.
- **Regresión:** quitar el lock de escritura separa la consulta de la reserva;
  cada petición puede observar un cupo vacío. El código anterior admite ambas.
- **Cobertura:** los casos secuenciales no prueban la admisión simultánea.
- **Seam:** no hay seam nuevo. El caso usa sesiones HTTP existentes y desactiva
  las transacciones de fixtures sólo en su clase para que dos conexiones observen
  los commits. Una barrera coordina el inicio; no suplanta Signup ni el lock.

## Política y mediciones

El máximo baja de un millón a 50 000 entradas y de 256 a 16 MiB para el
directorio. Se conserva el rechazo del EOCD antes de asignar el directorio y
antes de crear objetos por entrada, para ZIP y ZIP64. El directorio y el índice
están acotados por ambos valores. La indexación conserva la primera entrada
cuando se repite un nombre, como la búsqueda anterior. No se cambia el formato
de exportación ni se limita el tamaño total del ZIP a 16 MiB.

Se construyó una exportación por `Account::Export#build` sobre los fixtures del
repo: 93 entradas, directorio de 9 289 bytes y ZIP de 36 842 bytes. El límite
ofrece margen respecto de esa exportación y queda por debajo del presupuesto
medido. Es una exportación real del código, con datos de prueba; no es una
muestra de cuentas de producción. Una cuenta con más de 50 000 registros y
archivos exportados deberá dividir su transferencia o recibir otro mecanismo;
este trabajo no agrega ese mecanismo ni recorta silenciosamente un archivo.

Presupuesto de esta tarea para abrir el ZIP e indexarlo: **128 MiB adicionales
al proceso Rails y 10 segundos de CPU local**. No es un límite del contenedor ni
una garantía para todo el trabajo de validación SQL o extracción. Los límites
de bytes de contenido y relación de compresión anteriores siguen vigentes.

Se generaron tres ZIP válidos con Python `zipfile`, 50 000 nombres únicos de la
forma `data/cards/{n:025d}.json`, contenido `{}`, modo almacenado. Los casos de
comentarios y extras llenan exactamente los 16 MiB de directorio:
`spare = 16 * 1024**2 - sum(46 + len(name) for name in names)`. Cada entrada
recibe `spare // 50000 + (n < spare % 50000)` bytes de comentario o extras.
En extras, cada cuatro bytes son un campo de ID distinto, desde 2, con tamaño
cero (`id.to_bytes(2, "little") + b"\x00\x00"`); el resto es comentario.
Esto ejercita el costo del parser de extras sin comprimir ni extraer datos grandes.

En procesos Rails nuevos, se hizo `GC.start` antes de la medición. Se midieron
`ZipFile::Reader.new(file, limits: Account::Import::LIMITS)`, `glob`, `exists?`
y `read` de las 50 000 entradas, comprobando el contenido. La CPU se tomó con
`Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID)`; memoria adicional:
`VmHWM` posterior menos `VmRSS` inicial, leídos de `/proc/self/status`.

| Caso | Directorio | CPU | Tiempo real | RSS adicional | RSS máximo del proceso |
|---|---:|---:|---:|---:|---:|
| Nombres normales | 4,15 MiB | 1,53 s | 1,54 s | 55,68 MiB | 243,74 MiB |
| Comentarios | 16 MiB | 1,60 s | 1,60 s | 80,78 MiB | 269,05 MiB |
| Extras fragmentados | 16 MiB | 4,85 s | 4,87 s | 106,19 MiB | 293,97 MiB |

Comando por caso, con las mismas variables de entorno limpias y `RAILS_ENV=test`:
`mise exec -- bin/rails runner ../.context/handy-936-measure.rb
../.context/handy-936-<caso>.zip`. El script de medición permanece como evidencia
local; la descripción anterior permite repetir la carga sin datos privados.

La admisión usa un UPDATE de identidad antes de consultar importaciones de
cualquier cuenta y conserva la transacción hasta crear la importación y
programar su trabajo. La misma identidad queda ocupada mientras el estado sea
pending o processing. completed y failed liberan el cupo. No hay un vencimiento
que permita otra importación mientras la primera todavía está en curso.

## Lo que no se verificó

S3 real (se conserva la cobertura HTTP por rangos), MySQL, modo SaaS,
exportaciones de producción, archivos de cientos de GB y el costo del contenido
máximo de 1 TiB. Las medidas son del lector y de 50 000 entradas pequeñas;
no representan el costo de importar 50 000 registros a la base de datos.

## Validación final

Suite completa, mismo entorno con `PARALLEL_WORKERS=4`,
`mise exec -- bin/rails test`: salida 0; 1 873 casos, 7 430 aserciones,
cero fallos, cero errores y seis omisiones previas. Log local:
`.context/handy-936-suite.log`. RuboCop sobre los siete archivos Ruby del lote:
sin ofensas. No hay cambios visuales ni pasos manuales de configuración.
