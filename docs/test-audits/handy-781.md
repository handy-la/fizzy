# Cuenta única: registro e importación

## Autoría antes de editar las pruebas

Base: `f25c72da9ba17a7f184fa2c29673ad3670ff0546`.

- **Contrato:** con cuenta única y una cuenta existente, `Signup#complete` y
  `Account.create_with_owner` rechazan otra cuenta antes de crear tenant,
  usuarios, adjuntos, importaciones o jobs. Dos registros concurrentes en una
  base sin cuentas permiten un solo éxito. Dueño: `Account.create_with_owner`;
  fronteras: modelo, HTTP de finalización e importación y conexiones reales.
- **Regresión:** omitir el control permite otra cuenta; comprobar fuera del
  bloqueo permite dos primeros registros; crear el tenant antes del control
  deja recursos remotos al rechazar. Los negativos usan datos válidos.
- **Cobertura:** `SignupTest` cubre validaciones y un registro permitido;
  `AccountTest` cubre creación con propietario; `MultiTenantableTest` sólo
  consulta la política; `SignupsControllerTest` sólo protege el inicio.
  Se amplían las pruebas de modelo y se agregan pruebas HTTP porque un rechazo
  del modelo no demuestra respuesta de transporte ni ausencia de jobs de importación.
- **Seam:** sin API exclusiva para tests. El bloque de `create_with_owner`
  obtiene atributos remotos dentro de la operación autorizada; su consumidor
  productivo es `Signup#create_account`. La concurrencia usa conexiones reales
  y registros reales, sin simular la política ni la cuenta creada.

## Evidencia

Ruby 3.4.8 de mise, SQLite, `SAAS=false`. La base se exportó con
`git archive f25c72da9ba17a7f184fa2c29673ad3670ff0546` a
`.context/handy-781-base`, fuera del repo. Se copiaron sólo los cuatro archivos
de prueba finales. No se copió el arreglo ni la migración. Su almacenamiento
SQLite es independiente del worktree.

Comando GREEN, desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/models/signup_test.rb \
    test/models/single_tenant_signup_concurrency_test.rb \
    test/controllers/signups/completions_controller_test.rb \
    test/controllers/account/imports_controller_test.rb
```

RED: mismo entorno y selección, desde `fizzy-custom/`, con
el siguiente comando:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ruby -C ../.context/handy-781-base bin/rails test \
    test/models/signup_test.rb test/models/single_tenant_signup_concurrency_test.rb \
    test/controllers/signups/completions_controller_test.rb \
    test/controllers/account/imports_controller_test.rb
```
`ruby -C` conserva el Ruby seleccionado antes de entrar en la exportación.
Salida 1: 12 casos, 63 aserciones, 5 fallos, sin errores.

- Finalización por modelo y HTTP, e importación HTTP: invocación inesperada
  de `create_tenant`, declarado como nunca permitido en estos negativos.
- Creación directa con propietario: `StandardError expected but nothing was raised`.
- Dos primeros registros concurrentes: esperado `[false, true]`, obtenido
  `[true, true]`.

GREEN: salida 0, 12 casos, 95 aserciones, sin fallos ni errores.
La selección ampliada con `account_test.rb` y `multi_tenantable_test.rb`
pasó: 22 casos, 123 aserciones.
Los dos casos positivos HTTP usan un miembro real (`david`, role `member`);
la importación positiva usa un ZIP generado por `Account::Export#build`.

## Atomicidad y límites

`Account::SignupLock` usa una fila de id fijo, único por clave primaria.
`create_or_find_by!` resuelve su inicialización concurrente. Dentro de la
transacción, un UPDATE toma el bloqueo antes de consultar las cuentas:
bloqueo de escritura en SQLite y bloqueo de fila en MySQL. La segunda
consulta usa lectura con bloqueo y sin caché, también para MySQL con
REPEATABLE READ. La creación de cuenta, código de acceso y usuarios termina
antes de liberar el bloqueo. El tenant remoto se crea sólo en el bloque
aceptado de `create_with_owner`.

La prueba concurrente desactiva las transacciones de fixtures y usa dos
conexiones reales, con una barrera de inicio. Sólo el transporte externo se
sustituye por un contador y un id: no simula el control ni las escrituras.
Comprueba un éxito, un rechazo, un solo tenant, una cuenta y sus dos usuarios.

La suite completa usa `PARALLEL_WORKERS=2` con el mismo entorno y
`mise exec -- bin/rails test`: salida 0, 1806 casos, 7103 aserciones, sin
fallos ni errores, 6 omitidos. RuboCop revisó los diez archivos Ruby tocados:
salida 0, sin infracciones.

No verificado: MySQL, la suite SaaS y una llamada real a Queenbee. La ausencia
de llamadas remotas se observa en `create_tenant`, que es la extensión SaaS.
No se cambió el inicio del registro, ni la política de cancelación.

## Versiones de las pruebas

SHA-256 idénticos en RED y GREEN:

| Archivo | SHA-256 |
|---|---|
| `test/models/signup_test.rb` | `cefa143cc2256e71f17fd17b8a50a1884d238bdb404aae99ab448536c797b3fe` |
| `test/models/single_tenant_signup_concurrency_test.rb` | `1f5fa809f25707608ff02a89b9da78838aab7e012ac6bea34082d50032e15d43` |
| `test/controllers/signups/completions_controller_test.rb` | `24f21947bcd04e6ffa213b1c9262f50cf8f29b8a6a86d14fca3565b88d2e5bcd` |
| `test/controllers/account/imports_controller_test.rb` | `dd193353a5c1b0e7eba9219a87b6d49974a53172b8ba5bc4abadded818c280b9` |

## Corrección de la primera revisión: seed de desarrollo

Los dos controles encontraron que el seed OSS crea tres cuentas mediante
`create_with_owner`; el primer arreglo detenía la segunda. El seed ahora
activa `multi_tenant` sólo durante su ejecución en desarrollo, con restauración
en `ensure`. No hay parámetro nuevo de excepción en el registro público.

Validación manual, sin agregar API de prueba. Contrato: `db:reset` prepara
las tres cuentas de desarrollo y restaura la política del proceso.
Regresión: retirar el bloque de modo temporal detiene la segunda cuenta.
Cobertura anterior: la suite ejecuta con multi-tenant activo y no ejecuta el
seed de desarrollo; `test/setup-phases-test` sustituye el comando Rails.

Base de este defecto introducido: `84ef40721` (exportación aislada a
`.context/handy-781-seed-base`). Comando desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile RAILS_ENV=development MULTI_TENANT=false \
  mise exec -- ruby -C ../.context/handy-781-seed-base bin/rails db:reset
```

Antes: salida 1, `Account::MultiTenantable::SignupsClosed` al crear `37signals`,
después de `cleanslate`. Después de copiar sólo `db/seeds.rb` corregido:
salida 0, `cleanslate`, `37signals` y `honcho` completos. `db:prepare` también
reprodujo el fallo anterior en la base nueva.

Mismo entorno, validación de la restauración dentro del proceso:

```bash
mise exec -- ruby -C ../.context/handy-781-seed-base bin/rails runner \
  'Rails.application.load_seed; raise "account count" unless Account.count == 3; raise "mode leaked" if Account.multi_tenant; Current.reset; signup = Signup.new(full_name: "Extra", identity: Identity.first); raise "signup accepted" if signup.complete; puts "3 accounts; single tenant mode restored; public signup rejected"'
```

Salida 0: tres cuentas, configuración restaurada y registro público rechazado.
RuboCop sobre `db/seeds.rb`: salida 0, sin infracciones. Las pruebas de
registro y los modelos de producción no cambiaron en esta ronda.

Tras el rebase sobre `bd1bc8875c6aec4e15f0f1159f13693073aa460c`, la suite
completa se repitió con el mismo comando: salida 0, 1815 casos, 7125 aserciones,
0 fallos, 0 errores y 6 omitidos.
