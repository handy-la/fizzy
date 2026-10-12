# Admisión y cuota de importaciones

## Autoría antes de editar pruebas

Base: `1cde149e8e7b1f71fdcd25479ccb7ac3f5578f00`.

- **Contrato:** HTTP rechaza el ZIP comprimido mayor de 100 MiB, el tamaño expandido sin cuota, más de 10.000 registros y archivos inválidos antes de adjuntar o encolar. La cuota incluye el ZIP y su expansión, para Disk y S3. Cada identidad tiene un trabajo activo, hasta tres intentos en 24 horas y un presupuesto activo de 1 GiB. La reserva y los cupos usan un UPDATE de identidad antes de leer, y un UPDATE de cuenta antes de leer su saldo. Los errores terminales borran el ZIP y los datos parciales; los fallos de servicio conservan claves y cargo hasta completar el borrado. Dueños: ImportsController, Account::Import y Storage. Fronteras: HTTP, conexiones SQL reales y objetos de almacenamiento.
- **Regresión:** adjuntar antes de comprobar acepta un ZIP sin saldo; omitir el backend remoto deja pasar S3; contar sin bloquear permite dos trabajos activos; contar sólo los éxitos permite repetir archivos inválidos; leer capacidad desconocida como suficiente permite llenar disco. Soltar la reserva antes de borrar deja objetos sin cargo.
- **Cobertura:** imports_controller_test sólo prueba el modo de tenant y una admisión válida. import_test cubre espacio de disco tras adjuntar y permite capacidad desconocida. upload_reservation_concurrency_test cubre cargas directas, sin trabajos de importación. Se amplían los casos existentes de disco y limpieza; se agregan HTTP y concurrencia de la admisión, porque tienen fronteras distintas.
- **Seam:** no se agrega API exclusiva de pruebas. La admisión persistida la usa el controlador y la libera el modelo al terminar. Se usan ZIP reales. Sólo se reemplazan el lector storage_limit y el servicio S3 para no requerir un bucket; el lock y el saldo son SQL real. Los fallos de borrado y capacidad se inyectan en fronteras productivas.

No se retiran pruebas. Los casos de la tabla de admisión nueva tienen excepción RED: la base no tiene esa tabla ni esa entrada; el RED histórico se demuestra por HTTP con el controlador anterior intacto. La concurrencia se verifica con conexiones y filas confirmadas, sin mock de locks.

## Ajustes de los casos existentes, antes de editar

La capacidad desconocida ahora debe fallar por espacio, no avanzar hasta el JSON. El ZIP de esa ficha llevará account.json para llegar al control de capacidad. Las pruebas de df observarán el lector de clase compartido por HTTP y worker. La expansión forjada ajustará también el byte_size del metadata para alcanzar el contador de bytes reales; un caso separado rechazará metadata discrepante. El límite de relación esperado cambia a 50:1. El archivo inválido se espera purgado, y no conservado tras fallar. No se retira ninguna frontera: se conserva el rechazo por tipo de ZIP, el parseo de df, la expansión real y el borrado parcial.

## Evidencia RED y GREEN

La base completa se exportó con `git archive HEAD` a `.context/handy-943-red`
del workspace. No se usó otro worktree ni el source checkout. Se copiaron sólo
las pruebas candidatas. Ruby 3.4.8 de mise, SQLite, `SAAS=false`, Gemfile OSS.

Entorno y comando desde `fizzy-custom/` (RED cambia de directorio dentro del
proceso después de seleccionar Ruby):

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bash -c 'cd ../.context/handy-943-red && bin/rails test test/controllers/account/imports_controller_test.rb'
```

RED HTTP final: salida 1; nueve casos, 55 aserciones, siete fallos y cero
errores. La base encola trabajos para ZIP excesivo, cuota insuficiente (Disk y
S3), demasiados registros, repetición concurrente, ZIP inválido y capacidad de
disco desconocida. Los fallos son por recursos creados o trabajos encolados,
no por una tabla o API ausente.

RED del modelo, mismo entorno y exportación:
`bin/rails test test/models/account/import_test.rb --name "/cannot_be_determined|blob_metadata_cannot/"`.
Salida 1: dos casos, dos aserciones, dos fallos y cero errores. La base permite
capacidad desconocida y no rechaza byte_size discrepante con el ZIP.

GREEN del lote de HTTP, modelo, admisión y concurrencia de admisión, y job:
44 casos, 321 aserciones, salida 0. Después se agregó el caso HTTP de capacidad
desconocida y se hizo que el caso de cuota llegue al saldo de la cuenta ya
persistida: las dos lecturas previas usan una cuota suficiente; la tercera usa
la cuota baja, bajo el lock. Así no prueba sólo el límite global del ZIP.

Suite completa, mismo entorno con `PARALLEL_WORKERS=4` y
`mise exec -- bin/rails test`: **1.940 casos, 7.884 aserciones, cero fallos,
cero errores y seis omisiones**, salida 0. Incluye los 45 casos del lote final.

### Excepción RED del ciclo de vida nuevo

Los casos de reserva idempotente, saldo exacto, presupuesto por identidad,
liberación de cupo, borrado fallido y traspaso de blobs sin adjunto requieren
la tabla de admisión nueva. La base no puede ejecutar esas entradas sin un
error de tabla o método ausente. No se llama RED a ese error. El fallo
histórico se demuestra por los siete casos HTTP y los dos casos de modelo
anteriores. Las pruebas nuevas comprueban cargos persistidos, reserva
conservada tras fallar el servicio, limpieza posterior y descarga real de
objetos. Dos conexiones SQL confirmadas comprueban los locks: una identidad
obtiene un único cupo, y dos identidades con 600 MiB cada una no pueden
reservar más que el saldo de 1 GiB. No se reemplaza la transacción por un mock.

## Contrato operativo

Límites: ZIP de 100 MiB comprimido, 1 GiB expandido, 100 MiB por objeto,
1 MiB por JSON, 20.000 entradas, 10.000 registros, directorio de 4 MiB,
relación máxima 50:1. La reserva suma comprimido y expandido. La cuota
predeterminada de importación propia es 1 GiB; SaaS consulta storage_limit.
El presupuesto activo por identidad es 1 GiB incluso con una excepción mayor.
Una importación activa y tres intentos por ventana de 24 horas son comunes a
todas las cuentas de la identidad. Los intentos fallidos se conservan y la
limpieza no los borra hasta después de la ventana.

La reserva no caduca si quedan objetos sin borrar: se falla cerrado ante un
worker interrumpido o un servicio no disponible. El job usa también el lease
de Solid Queue por identidad durante 24 horas, incluido un envío duplicado.
Las reanudaciones vuelven a comprobar límites y espacio; una reserva idéntica
se conserva sin duplicar su cargo. El archivo adjunto lo crea el servidor y no
se emite una URL PUT que permita reemplazarlo.

La conciliación final y la transferencia a cargo de adjuntos o reservas de
blobs sin adjunto ocurren en la misma transacción bajo el lock de cuenta.
Los blobs sin adjunto usan la conservación de borrador ya existente, 30 días.
Los campos de cuota del archivo exportado se reemplazan por metadatos locales;
los demás metadatos se conservan. byte_size debe coincidir con la entrada del
ZIP. Un cargo de adjuntos mayor al saldo también falla y se purga.

Un rechazo después del alta cancela la cuenta local y su alta externa de SaaS.
La purga borra el objeto antes de sus filas y no encola una segunda purga para
un blob ya eliminado. Si el servicio falla, se conservan la clave y la reserva;
la limpieza de imports fallidos vuelve a intentarlo. No hay paso manual tras
el despliegue normal y su migración. No hay cambio visual.

## Qué no pude verificar

No ejecuté un bucket S3 real, MySQL, el entorno SaaS completo, pruebas de
sistema ni un apagado real del worker. Los rechazos usan la clase S3 real sin
HTTP al proveedor; la cuota y la concurrencia usan SQLite. Un proceso muerto
entre reclamar el cupo y crear el import conserva su admisión sin vencimiento
por seguridad; este lote no incorpora recuperación automática de ese caso.
Las omisiones pertenecen a la suite existente.

Huella SHA-256 de la prueba HTTP, idéntica en RED y GREEN:
`b844b868c4d0e18b8aa9678fa6a30844fe1ba631a05669e7daf243cb87d05b53`.
Huella de la prueba de modelo aplicada al RED y GREEN:
`7cb46604ed07164bb7374d401d2bd29593473e934cc481b90a824272ba110523`.
RuboCop de los 11 archivos de lógica y pruebas: salida 0, sin infracciones.
`git diff --check`: salida 0.

Tras rebase sobre `c4f525ef777dbf57572aa1157406cdc5e11b8e2e`, se repitió la
suite completa con el mismo entorno: salida 0, **1.949 casos, 7.900 aserciones,
cero fallos, cero errores y seis omisiones**. No cambió código productivo de
esta tarjeta entre las dos suites.

## Integración tras la aprobación: autoría antes de editar pruebas

La nueva base de origin/main conserva una operación `Account::Import.start`
y pruebas HTTP de cupo para imports antiguos sin fila Admission. Se conservarán
esa entrada, el semáforo actual de Solid Queue y todos esos casos. La entrada
start usará la admisión persistida antes de crear la cuenta o el archivo.

- **Contrato:** imports pending/processing anteriores al despliegue bloquean una
  nueva petición de la misma identidad. Completed/failed y otras identidades
  dejan pasar un ZIP válido. Dos sesiones HTTP simultáneas sólo admiten una.
  Dueños: Import.start, Admission.claim y el controlador. Fronteras: HTTP real
  y dos conexiones SQL confirmadas.
- **Regresión:** contar sólo filas Admission ignora los imports anteriores;
  aceptar PNG como ZIP deja pasar archivos inválidos; cambiar la clave del job
  separa los semáforos de trabajos anteriores y nuevos.
- **Cobertura:** se conservan las pruebas de estado y carrera incorporadas en
  origin/main; las de esta tarjeta cubren además cuota y rate. Sus fixtures PNG
  se sustituyen por ZIP reales para llegar al control correcto sin un rechazo
  previo por formato. No cambian las aserciones de estado, recursos ni trabajos.
- **Seam:** ninguno. start es la entrada productiva del controlador. Se usa
  ZipFile::Writer y solicitudes reales. La clase de pruebas de modelo se renombra
  para evitar colisión con la clase HTTP de la nueva base; conserva todos los casos.

**Excepción RED limitada a estos ajustes de integración:** se conservan contratos
ya cubiertos por la base y por el RED previo de esta tarjeta; no se presenta un
error de constante duplicada o de rebase como RED. La validación integrada
comprueba todos los casos existentes y nuevos sobre la nueva base. No se retiran
pruebas, locks ni la entrada productiva start.

Los dos casos productivos de StructureTest se ajustan a 20.001 entradas y un
directorio mayor de 4 MiB. Conservan el contrato de rechazo antes del parser;
volver a 50.000/16 MiB debe fallar. Los casos existentes de ZIP64 y límites
artificiales no fijan esta política nueva. Se usa el lector productivo y el
RecordingIO existente, sin seam nuevo; los límites esperados son literales,
independientes de las constantes del código que se comprueba.
