# Revocación con réplica atrasada: Handy 965

## Problema

Con réplica configurada (modo SaaS, MySQL), `DatabaseSelector` sirve las
lecturas desde la réplica. La sesión, la identidad, el usuario, su rol, la
marca de staff y el estado de la cuenta se leían allí. `TransactionPinning`
sólo espera la última transacción de la misma sesión, así que una revocación
hecha por otro actor no se esperaba. Además, si `WAIT_FOR_EXECUTED_GTID_SET`
vencía, la solicitud seguía en la réplica, y si fallaba se trataba como al día.

El Fizzy de Handy corre en modo OSS con SQLite y sin réplica, así que hoy
`with_writing_role` no cambia nada en producción. El arreglo protege el modo
con réplica.

## Política

- `Authentication#resume_session` y la autenticación por token leen sesión,
  identidad y usuario dentro de `ApplicationRecord.with_writing_role`.
  `Current.identity=` carga el usuario en ese bloque, con rol y `active`.
- `Authorization#ensure_can_access_account` evalúa `Account#active?` y
  `User#active?` en el writer.
- `TransactionPinning::Middleware` sirve toda la solicitud desde el writer
  (`ActiveRecord::Base.connected_to(role: :writing)`, con el mismo
  `prevent_writes`) si la espera vence o falla.

Límite: el acceso a un tablero (`Access`) se sigue leyendo en la réplica.
Desactivar un usuario borra sus accesos y además lo marca inactivo, y eso sí
se comprueba en el writer.

## Autoría antes de editar las pruebas

- **Contrato:** una revocación que otro actor ya escribió en el writer se
  aplica en la siguiente solicitud, aunque la réplica no la tenga. Dueños:
  `Authentication`, `Authorization`, `Current` y
  `TransactionPinning::Middleware`. Frontera: solicitudes HTTP reales con
  cookie o token, y el middleware con la función GTID simulada.
- **Regresión:** quitar `with_writing_role` de la autenticación o de
  `ensure_can_access_account` da 200 a un usuario desactivado, a un admin
  degradado, a un staff retirado, a un token de usuario desactivado o a una
  cuenta cancelada. Volver a `true` en el `rescue`, o no cambiar de rol al
  vencer la espera, sirve la solicitud desde la réplica.
- **Cobertura:** `UsersControllerTest` y `Admin::MissionControlTest`
  prueban revocación y staff sin réplica; la base de pruebas es una sola, así
  que no ven una lectura atrasada. No había prueba del middleware.
- **Seam:** ninguno nuevo. `test/integration/replica_revocation_test.rb`
  simula la réplica con módulos antepuestos: fuera de `with_writing_role` el
  método dado responde el valor viejo. Los módulos se vacían al terminar.
  `saas/test/lib/transaction_pinning_test.rb` reemplaza la conexión con un
  objeto que responde `WAIT_FOR_EXECUTED_GTID_SET`, que SQLite no tiene.

## Evidencia

Base del repo: `fb2af95ebcd8317391d7b3c7f715d22f97e81ffb` (`origin/main`).
RED: las pruebas nuevas, con los tres archivos productivos restaurados desde
esa base en este checkout; GREEN: los mismos archivos de prueba con el
arreglo. SHA-256 de las pruebas, iguales en RED y GREEN:

- `test/integration/replica_revocation_test.rb`:
  `84f0778eaf5e3ea351f32e4903ca6e1219870f583b3614cb61519dd0e44634c0`.
- `saas/test/lib/transaction_pinning_test.rb`:
  `984244186f37cd3420c78bb2197e57e92557e8726b3b95028c9406d76b691269`.

Comando desde `fizzy-custom/`, Ruby 3.4.8 de mise, SQLite OSS:

```bash
env -u GEM_HOME -u GEM_PATH -u BUNDLE_GEMFILE -u RUBYOPT -u RUBYLIB \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/integration/replica_revocation_test.rb
```

- RED: `5 runs, 13 assertions, 5 failures`; cada caso esperaba 403 y
  recibió 200.
- GREEN: `5 runs, 13 assertions, 0 failures, 0 errors`.

El bundle SaaS necesita gemas privadas de 37signals y no se instala en esta
máquina. La prueba del middleware se corrió con el bundle OSS y un shim
local fuera del repo. Para reconstruirlo, crea `$SHIM/yabeda/testing.rb`
con este contenido exacto (lo carga el `require "yabeda/testing"` de la
prueba):

```ruby
# Local shim only: the SaaS bundle (private 37signals gems) cannot be installed on this machine.
# Defines just what TransactionPinning touches, so its SaaS test can run under the OSS bundle.
module Yabeda
  Metric = Struct.new(:name) do
    def increment(*) = nil
    def measure(*) = yield
  end
  def self.fizzy = Struct.new(:replica_stale, :replica_wait).new(Metric.new(:stale), Metric.new(:wait))
end
module Sentry
  def self.capture_exception(*) = nil
end
require File.expand_path("saas/lib/fizzy/saas/transaction_pinning", Dir.pwd)
```

Comando desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u BUNDLE_GEMFILE -u RUBYOPT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  RUBYLIB="$SHIM" \
  mise exec -- bin/rails test saas/test/lib/transaction_pinning_test.rb
```

Para RED, los archivos productivos se restauraron con
`git show fb2af95ebcd8317391d7b3c7f715d22f97e81ffb:<archivo> > <archivo>`
(`app/controllers/concerns/authentication.rb`,
`app/controllers/concerns/authorization.rb`,
`saas/lib/fizzy/saas/transaction_pinning.rb`), se corrieron ambos comandos y
se volvió a copiar el arreglo. El shim sustituye sólo las métricas y Sentry;
la prueba espera `Sentry.capture_exception` con mocha, y el rol y
`prevent_writes` los observa la app de la prueba:

- RED: `4 runs, 5 assertions, 2 failures`; los casos de vencimiento y error
  esperaban `[[:writing, true]]` y recibieron `[[:reading, true]]`. Los dos
  casos de réplica al día pasan en la base, como control.
- GREEN: `4 runs, 7 assertions, 0 failures, 0 errors`.

No verificado: la prueba del middleware con el bundle SaaS real y MySQL, y
una réplica MySQL real.
