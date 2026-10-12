# Importaciones: errores terminales y reanudación limitada

## Autoría antes de editar pruebas

- **Contrato:** `RecordSet#check` y `#import` rechazan JSON inválido, valores
  que no sean objetos y texto con encoding inválido como `IntegrityError`.
  `DataImportJob` termina sin reanudación para esos archivos y envía un único
  aviso. Sólo errores concretos de red o bloqueo de base permiten reanudación,
  con un máximo de tres, también antes del primer cursor. Un intento transitorio no marca el import como fallido
  ni envía aviso; el agotamiento sí. Fronteras: ZIP real, estado persistido,
  cola serializada de Active Job y correo encolado.
- **Regresión:** permitir que `JSON::ParserError` escape después del primer
  cursor, reanudar cualquier `StandardError`, quitar el límite o enviar correo
  desde el rescate transitorio reproduce el fallo de la tarjeta.
- **Cobertura:** `record_set_test.rb` sólo probaba estructura de asociaciones y
  claves únicas. `data_import_job_test.rb` prueba un conflicto y un reset de
  conexión tras `check`, pero no JSON inválido tras avanzar, agotamiento,
  repetición del job ni número de correos. Se amplía el caso transitorio
  existente. Las pruebas del modelo conservan el contrato de estado terminal.
- **Seam:** no se agrega API exclusiva de pruebas. ZIP de tamaño pequeño se
  crea con el escritor productivo. Mocha inyecta fallos en `zip.read` y
  `ensure_sufficient_storage_space`: el primero permite comprobar TypeError y
  EncodingError del lector; el segundo simula infraestructura antes de leer.
  El caso transitorio existente falla en la segunda reserva de espacio;
  `check` y `process` son reales. El agotamiento inyecta `process` para
  comprobar la reanudación de un paso que no vuelve a avanzar.
  Las reanudaciones se ejecutan desde los bytes serializados por Active Job.

No se retiran pruebas ni seams. La evidencia RED/GREEN se registra al ejecutar.

## Evidencia RED y GREEN

Base de Fizzy: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`, sin arreglo.
Se exportó con `git archive HEAD` a `.context/handy-932-base` del workspace;
se copiaron únicamente las dos pruebas candidatas. Ruby 3.4.8, SQLite,
`SAAS=false`; ninguna dependencia ni error de preparación causó el RED.

Comando desde cada checkout (base exportada y `fizzy-custom/`):

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  MISE_TRUSTED_CONFIG_PATHS="$PWD" mise exec ruby@3.4.8 -- bin/rails test \
  test/models/account/data_transfer/record_set_test.rb \
  test/jobs/account/data_import_job_test.rb
```

Las dos versiones tienen estos SHA-256:

- Job: `c314689ff7abf0f55afd12951276e48ed77f5052b943d491c044b7f93e24921d`.
- RecordSet: `473104f4c8b3f64a1eab8bd19f2e463e1138f9cc1629dab5187c32e4133dd07d`.

RED: salida 1, 37 casos, 19 fallos y 3 errores. JSON mal formado se escapa
como `JSON::ParserError`; los valores JSON que no son objetos producen errores
de tipo o restricciones SQL. Los dos ZIP dañados encolan una reanudación.
El reset temporal envía correo prematuro. `NoMethodError` se reanuda.
Los errores transitorios antes del cursor y el reset en un paso reanudado
se escapan sin control terminal. El texto UTF-8 inválido tampoco se rechaza
como un fallo de integridad. Log local: `.context/handy-932-red-final.log`.

GREEN: el mismo comando da 37 casos sin fallos ni errores. La prueba del ZIP
con JSON dañado comprueba el último cursor válido, cero reanudaciones, motivo
`invalid_export`, un aviso y cero avisos adicionales al ejecutar otra vez.
El proceso comprueba también un error tras completar `check`. Los casos
transitorios ejecutan las reanudaciones serializadas: máximo de tres, sin
correo intermedio y un aviso al agotar el límite. La recuperación usa
`check` y `process` reales y termina con el correo de éxito.

Suite completa con el mismo entorno, `PARALLEL_WORKERS=2` y `bin/rails test`:
1888 casos, 7464 aserciones, cero fallos, cero errores y seis omisiones.
RuboCop de los cinco archivos Ruby tocados: cero ofensas. Sin cambios visuales.

No verificado: S3 real, MySQL, apagado real del worker ni archivos de cientos
de GB. No se retiró cobertura; las omisiones pertenecen a la suite existente.
