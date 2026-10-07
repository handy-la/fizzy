# Cancelación de cuentas y sugerencias de IA

## Autoría antes de editar las pruebas

Base productiva: `25a93b13ec5a819fed72f956b64f7da424b5a852`.

- **Contrato:** una cuenta cancelada no puede iniciar o recuperar sugerencias,
  conectar Cable ni mantener conexiones abiertas. La cancelación revoca las
  solicitudes pendientes, en ejecución y terminadas, sin afectar otra cuenta.
  Dueños: `Card::SuggestionRequest`, `Account::Cancellation`, la conexión y
  `CardSuggestionChannel`. Fronteras: job real con HTTP de proveedor controlado,
  almacenamiento, conexión de Cable y transmisión del canal.
- **Regresión:** omitir la comprobación de cuenta permite el POST al proveedor
  después de cancelar; omitir la revocación conserva texto o permite que un
  resultado tardío lo reponga. Omitir los controles del canal o la conexión
  permite entregar texto o reconectar. Omitir el cierre deja sockets abiertos.
- **Cobertura:** `suggestions_controller_test.rb` cubre cola, vigencia y tokens,
  pero no cancelación. `card_suggestion_channel_test.rb` revoca acceso a un
  tablero; esa revocación no cancela la cuenta. `connection_test.rb` prueba
  sesión y cuenta ausente, pero no cuenta inactiva. `cancellable_test.rb`
  comprueba la cancelación y reactivación sin observar solicitudes ni Cable.
  Se amplían esos archivos; cada frontera tiene un riesgo independiente.
- **Seam:** se usan POST, el job encolado, `cancel`, `recover`, `connect` y el
  adaptador de Cable existentes. WebMock sustituye sólo el proveedor externo.
  Los callbacks de WebMock permiten cancelar durante una llamada ya iniciada.
  Los dobles de Cable observan el cierre por usuario de cuenta. No se agrega
  API productiva para pruebas ni se retira cobertura previa.

Los controles de actividad del worker se prueban también sin callbacks de
cancelación (`insert_all!`): simulan una revocación ya visible desde otro
proceso, antes de su limpieza. El caso del canal durante `state` conserva un
estado anterior y cancela antes de `transmit`: detecta la entrega de texto ya
leído. El caso de rollback protege la atomicidad y el orden del cierre;
es cobertura preventiva y puede pasar sobre la base.

### Corrección tras la primera revisión

`Account#active?` también excluye cuentas en importación. La pantalla
`account/imports/show` usa Cable para mostrar su progreso: rechazar esa
conexión rompe un consumidor productivo. Para Cable general, el contrato es
cuenta existente y sin cancelación; la IA mantiene el requisito `active?`.
La prueba de conexión en importación conserva sesión, usuario y contexto de
cuenta válidos. Debe pasar en la base y fallar si se usa `active?` en la
conexión general. No agrega un seam. Se corrige la expectativa anterior y no
se retira cobertura de seguridad: la prueba de cuenta cancelada permanece.

## Evidencia

Se exportó la base con `git archive` a `.context/handy-783-base`. Se copiaron
sólo los cuatro archivos candidatos de prueba. SQLite queda dentro de cada
checkout; no se usó otra tarjeta ni el source checkout.

SHA-256 de los candidatos, idénticos en ambas ejecuciones:

| Archivo bajo `test/` | SHA-256 |
|---|---|
| `controllers/cards/suggestions_controller_test.rb` | `24d98e8defd8f172c6088bd7dd8358c4b98cc7363cbc240d14854c982428116c` |
| `channels/card_suggestion_channel_test.rb` | `9a1da21368a2ff12e6be7b4ff6e74786380b6fee596fa319783f2afc7bde8830` |
| `channels/application_cable/connection_test.rb` | `0845c8ce90569ca0d43e5c6d5e4df2405530e95fb1eb8ec3754be3d0dab0335c` |
| `models/account/cancellable_test.rb` | `6806c061407f9ccad7dc5f95053163782e832e1473677a67f848f9ef6914e768` |

Comando RED exacto, desde `fizzy-custom/`, con Ruby 3.4.8 de mise y SQLite:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ruby -e 'Dir.chdir("../.context/handy-783-base"); exec("./bin/rails", "test", "test/controllers/cards/suggestions_controller_test.rb", "test/channels/card_suggestion_channel_test.rb", "test/channels/application_cable/connection_test.rb", "test/models/account/cancellable_test.rb")'
```

RED: salida 1; 36 casos, 264 aserciones, 10 fallos, cero errores y omisiones.
Los cuatro casos del worker llaman al proveedor o guardan un resultado después
de cancelar. Los tres del canal entregan texto o permiten suscripción. La
conexión admite una cuenta cancelada. Los dos de cancelación conservan
solicitudes o no cierran conexiones. El rollback y la conexión de importación
pasan sobre la base.
Evidencia local: `.context/handy-783-red.log`.

GREEN: mismo entorno y archivos, ejecutados en `fizzy-custom/` con:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/controllers/cards/suggestions_controller_test.rb \
  test/channels/card_suggestion_channel_test.rb \
  test/channels/application_cable/connection_test.rb \
  test/models/account/cancellable_test.rb
```

Salida 0; 36 casos, 297 aserciones, cero fallos, errores y omisiones.
Evidencia local: `.context/handy-783-green.log`.

### Sensibilidad del flujo de importación

Se exportó el primer arreglo `cc55c151a93630ba8814abcfef0e07477e26903f`
a `.context/handy-783-first-fix`, que usaba `Account#active?` en la conexión.
Se copió sólo el archivo final `connection_test.rb`. Con el mismo entorno
del comando RED, se ejecutó desde `fizzy-custom/`:

```bash
mise exec -- ruby -e 'Dir.chdir("../.context/handy-783-first-fix"); exec("./bin/rails", "test", "test/channels/application_cable/connection_test.rb")'
```

Salida 1; 5 casos, 7 aserciones y un error de autorización: la conexión del
importador válido fue rechazada por `connect`. Es el defecto del primer
arreglo, no un error de entorno. El mismo caso pasa en la base original y
en el GREEN final. Evidencia: `.context/handy-783-import-red.log`.

## Validación del repo

Se usa el mismo entorno Ruby limpio, `SAAS=false`, `BUNDLE_GEMFILE=Gemfile`
y `CI_PROGRESS_BAR=false`.

| Comando en `fizzy-custom/` | Resultado |
|---|---|
| `PARALLEL_WORKERS=4 mise exec -- bin/rails test` | Salida 0; 1.782 casos, 6.980 aserciones, 6 omisiones, sin fallos ni errores |
| `PARALLEL_WORKERS=1 mise exec -- bin/rails test:system` | Salida 0; 43 casos, 322 aserciones, sin fallos, errores ni omisiones |
| `mise exec -- bin/rubocop -f simple` sobre los ocho archivos Ruby del diff | Salida 0; sin infracciones |
| `mise exec -- ruby script/check_agents_docs` | Salida 0; cuatro documentos |
| `git diff --check` | Salida 0 |

## Lo que no se verificó

No se llamó al proveedor real ni se canceló una petición externa en curso.
La reproducción usa los fixtures y HTTP controlado. No se validaron MySQL,
el modo SaaS ni un despliegue. No hay migración ni cambio visual.
