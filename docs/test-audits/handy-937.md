# Admisión de exportaciones concurrentes

## Autoría antes de editar pruebas

Base del repo: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.

- **Contrato:** los POST de exportación de cuenta y usuario admiten como máximo
  diez exportaciones por principal en 24 horas. Sólo las aceptadas crean una
  fila y encolan `DataExportJob`; las demás responden 429. Además, como máximo
  diez exportaciones pendientes o en ejecución pueden ocupar cupos, incluso
  después de 24 horas. Los estados completed y failed liberan esos cupos,
  sin liberar el límite diario. Dueños: ambos controladores y `Export`.
  Fronteras: HTTP concurrente, transacciones reales y cola.
- **Regresión:** separar el conteo de la inserción permite que solicitudes
  simultáneas acepten más de diez; excluir pendientes antiguos deja crecer la
  cola; incluir estados terminales en el cupo impide reutilizarlo.
- **Cobertura:** `accounts/exports_controller_test.rb` y
  `users/data_exports_controller_test.rb` prueban límite y fecha sólo en serie.
  Se conservan y amplían para estados y rechazos sin jobs. La prueba nueva
  `exports_concurrency_test.rb` observa HTTP y conexiones independientes con
  datos confirmados. Las pruebas de build existentes cubren ZIP, completed y
  failed, pero no la admisión posterior a esas transiciones.
- **Seam:** ninguno productivo nuevo para pruebas. La reserva es la entrada
  productiva de ambos controladores. La prueba concurrente usa sesiones HTTP
  independientes y una notificación SQL para añadir 50 ms después del conteo;
  no cambia su resultado ni sustituye el lock. La pausa amplía la ventana real
  de carrera y permite comprobar que el bloqueo la cierra.

## Límites de ejecución

El límite diario actual se conserva. El cupo de trabajo es independiente de la
fecha, y se libera con el estado terminal. Solid Queue debe ejecutar como máximo
un ZIP a la vez por principal, con un lease de 24 horas; la admisión sigue protegida incluso con otro
adaptador de cola. No se cambia la retención de archivos ni la autenticación.

## Autoría de la prueba de configuración de cola

- **Contrato:** `DataExportJob` entrega a Solid Queue un límite de uno y claves
  compartidas por cuenta para ZIP completos, y por usuario para ZIP personales.
  Los tipos y principales distintos tienen claves distintas. Frontera: API de
  concurrencia del job consumida por Solid Queue.
- **Regresión:** quitar el límite o usar el ID de exportación permite paralelismo
  para el mismo principal; usar sólo el usuario en ZIP completos divide la cuota
  de una cuenta entre administradores; una clave global bloquea otras cuentas.
- **Cobertura:** las pruebas existentes sólo verifican enqueue y construcción.
  La prueba HTTP usa el adaptador test, que no ejecuta semáforos de Solid Queue.
- **Seam:** ninguno. Se comprueban `concurrency_limit` y `concurrency_key` de jobs
  reales con registros distintos; no se fija el texto exacto de la clave.

El caso anterior de exportaciones antiguas ahora usa completed de forma explícita:
se conserva la frontera de 24 horas y se separa el nuevo límite de pendientes.

## Evidencia RED y GREEN

Ruby 3.4.8 de mise, SQLite y Gemfile OSS. Base exportada con `git archive HEAD`
a `../.context/fizzy-937-red` desde `fizzy-custom/`; HEAD era la base completa
indicada arriba. Se copiaron únicamente las pruebas candidatas a la exportación.
No se modificó otro checkout. Entorno común a todas las ejecuciones:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bash -c 'cd ../.context/fizzy-937-red && bin/rails test test/controllers/exports_concurrency_test.rb test/controllers/accounts/exports_controller_test.rb test/controllers/users/data_exports_controller_test.rb'
```

RED: salida 1; 42 casos, 243 aserciones, cuatro fallos y cero errores. Ambos
endpoints responden 201 doce veces; se esperaban diez. Ambos casos con diez
exportaciones antiguas pendientes o processing encolan un job indebidamente.
Las pruebas de liberación y de conservación del límite diario ya pasan en la
base, y protegen las transiciones existentes.

Con el mismo entorno y directorio de la base, el selector
`bin/rails test test/jobs/data_export_job_test.rb` da salida 1: dos casos,
dos fallos, cero errores. El límite de concurrencia del job es nil en ambos.

GREEN, desde el checkout corregido, con el mismo entorno y este selector:

```bash
mise exec -- bin/rails test test/controllers/exports_concurrency_test.rb test/controllers/accounts/exports_controller_test.rb test/controllers/users/data_exports_controller_test.rb test/jobs/data_export_job_test.rb test/models/account/export_test.rb test/models/user/data_export_test.rb
```

Salida 0: 57 casos, 310 aserciones, cero fallos, errores u omisiones. Las 12
solicitudes de cada tipo producen diez registros, diez jobs con sus IDs exactos
y dos respuestas 429. Se construye un ZIP real para completed y se fuerza un
fallo de escritura para failed antes de comprobar la nueva admisión.

SHA-256 de las pruebas, iguales en RED y GREEN:

- `test/controllers/exports_concurrency_test.rb`: `aa92ca919b91e7bf0b11401992140a1966efc5d9547ddca009a98e6b1369a7f1`
- `test/controllers/accounts/exports_controller_test.rb`: `b6b079f85c2b516283c7be16ab8b3917682eab93f2772855c2135bf6e7e4a725`
- `test/controllers/users/data_exports_controller_test.rb`: `15e235e6a2fd26ecd5503b74bd7e4a273dadda7bf320a6d64a350f410b455ee7`
- `test/jobs/data_export_job_test.rb`: `c248bbb512a7800745286790d25897d5c2ef563505b4bf030059754155df3eda`

Suite completa con el mismo entorno y `PARALLEL_WORKERS=4`, comando
`mise exec -- bin/rails test`: salida 0; 1.879 casos, 7.465 aserciones,
cero fallos, cero errores y seis omisiones existentes. RuboCop de los diez
archivos Ruby del lote, `git diff --check` y `script/check_agents_docs`:
salida 0. No se hicieron cambios de código ni pruebas después de esta suite.

## Lo que no se verificó

No se ejecutó contra MySQL ni contra workers distribuidos de Solid Queue.
El lease evita ZIP simultáneos por principal durante 24 horas; después de ese
plazo Solid Queue puede recuperar el cupo aunque el proceso original siga vivo.
La prueba de job comprueba las claves y el límite que recibe Solid Queue, sin
simular sus semáforos. La prueba HTTP sí usa transacciones y conexiones reales.
No se cambió la lógica existente de fallo de ZIP, limpieza ni retención.
