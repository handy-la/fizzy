# Estado de webhooks HTTP heredados: Handy 958

Hallazgo de [Handy 941](https://hermes.tailbaa835.ts.net:43008/1/cards/941).
Un webhook HTTP desactivado por la migración de 941 conserva su URL. Cambiar
su estado validaba esa URL y lanzaba `ActiveRecord::RecordInvalid`:

- reactivarlo desde `Webhooks::ActivationsController#create` respondía 422
  sin decir por qué;
- desactivarlo por morosidad en `DelinquencyTracker#record_delivery_of`
  dejaba la entrega en `errored` y el webhook activo.

## Autoría antes de editar las pruebas

- **Contrato:** `Webhook#deactivate` sólo escribe `active` y `updated_at`,
  aunque la URL guardada no sea válida, y no guarda otros cambios sin validar.
  `Webhook#activate` devuelve falso si la validación rechaza el destino.
  La activación responde con el motivo: aviso en HTML y errores con 422 en JSON.
  HTTP sigue sin poder activarse ni enviarse.
- **Regresión:** volver a `update!` en cualquiera de los dos métodos repite el
  error; usar `update_attribute` o `save(validate: false)` para desactivar
  guarda también una URL HTTP cambiada en memoria, sin validación.
- **Cobertura:** las pruebas de 941 (`blocks legacy HTTP deliveries…`) usan un
  contador de morosidad bajo y nunca llegan a `deactivate`.
  `DelinquencyTrackerTest` y `ActivationsControllerTest` sólo usan URLs HTTPS.
  Se agregan: entrega HTTP heredada con nueve fallos de hace dos horas
  (`DeliveryTest`), desactivación HTTP con URL sucia en memoria y `updated_at` renovado (`WebhookTest`)
  y reactivación HTTP en HTML y JSON (`ActivationsControllerTest`).
  No se retiran pruebas.
- **Seam:** entradas productivas `deliver`, `deactivate` y `POST` de la
  activación. Mocha sólo prohíbe DNS y `Net::HTTP`. Sin API nueva.

## Evidencia RED y GREEN

Base del repo: `087f76c60d31d4b052197c177bfe4210cab88cd8`. Ruby 3.4.8 con
mise, SQLite, sin SaaS. Comando, desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/controllers/webhooks/activations_controller_test.rb \
  test/models/webhook/delivery_test.rb test/models/webhook/delinquency_tracker_test.rb \
  test/models/webhook_test.rb
```

- RED con el código base y las tres pruebas nuevas de entrega y activación:
  salida 1; 61 casos, dos fallos y un error. La entrega lanzó
  `RecordInvalid: Url must use https` desde `Webhook#deactivate`; la activación
  respondió 422 sin errores en HTML y en JSON.
  Log: `.context/handy-958-red.log` en la raíz del workspace.
- RED de `deactivate a legacy HTTP webhook saves only its state` con el modelo
  base: `RecordInvalid` desde `update!`. Log: `.context/handy-958-red2.log`.
- Sensibilidad (mutación temporal, no RED histórico): con `update_attribute`
  esa prueba falla porque guarda la URL HTTP sucia; salida 1.
  Log: `.context/handy-958-sensitivity.log`. Con `update_columns active: false`
  falla porque `updated_at` no cambia; salida 1.
  Log: `.context/handy-958-sensitivity2.log`.
- GREEN del mismo comando: salida 0; 62 casos, 287 aserciones, cero fallos,
  errores u omisiones. Log: `.context/handy-958-green.log`.

## Validación y límites

- Suite OSS completa, mismo entorno con `PARALLEL_WORKERS=4` y
  `mise exec -- bin/rails test`: salida 0; 2.046 casos, 8.614 aserciones,
  cero fallos y errores, seis omisiones. Log: `.context/handy-958-suite.log`.
- RuboCop en los cinco archivos Ruby: sin infracciones. `git diff --check`: 0.

Un webhook HTTP sigue sin poder corregirse en su edición: `update` excluye la
URL desde antes de 941. La salida para el usuario es crear uno nuevo con HTTPS.
No se ejecutaron MySQL, SaaS ni la suite de navegador. No se cambió producción.
