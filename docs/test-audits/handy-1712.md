# Sincronización de Basecamp: Handy 1712

Base del fork: `b21a1a71996d0a7667c9c2f25cfe040ccbc1c97f`.
Upstream: `08f757809cf54602fac5e6abfd974aedb376cbcd`, 540 commits (41 en la
primera línea de padres). Merge con segundo padre; sin cherry-pick. Un fetch
antes de revisar confirmó que upstream seguía en ese SHA.

## Qué trae upstream

- Servidor de autorización OAuth 2.1 (descubrimiento, registro dinámico,
  documentos de metadatos de cliente, PKCE S256, rotación y caducidad de
  tokens, audiencia RFC 8707, intercambio RFC 8693, pantalla «Connected
  Apps»). Producción lo deja apagado: `OAUTH_ACCEPTANCE_ENABLED` vale `false`
  si no se define, y el descubrimiento responde 404.
- Los tokens se guardan como digest HMAC. Las migraciones `20261015120100` y
  `20261016120100` calculan el digest de cada token personal y lo asignan al
  cliente `fizzy-personal-access`; el token, su permiso y su falta de
  caducidad no cambian, así que los tokens que ya usa Dédalo siguen válidos.
  Un token personal sólo se muestra en la respuesta que lo crea.
- MySQL pasa de Trilogy a mysql2 (el Dockerfile instala `libmariadb`).
- Otros: código de invitación canjeado bajo lock, firmas de URLs de
  almacenamiento filtradas de los logs, importación que tolera columnas
  nuevas, webhooks limitados a su cuenta, cargas directas firmadas con una
  credencial de sólo escritura (SaaS), sqlite3 2.10.2, thruster 0.1.27,
  net-ssh 7.3.8, GC por omisión de Ruby, IP real de cliente en el balanceador
  SaaS.

## Resolución de conflictos y personalizaciones

| Archivo | Decisión |
|---|---|
| `concerns/authentication.rb` | Se adopta `authenticate_with_bearer_token` de upstream dentro de `ApplicationRecord.with_writing_role` (Handy 965): token, identidad y concesión se leen en el writer. |
| `users/push_subscriptions_controller.rb` | Se conserva el controlador del fork: sólo una sesión de navegador registra push (Handy 928). Un token, personal u OAuth, recibe 403; `claim_for` de upstream no se llama. |
| `notification/push_target/web.rb` | `active` del fork, más `deliverable_to` de upstream, más el orden y límite del fork. |
| `board/accessible.rb` | Se conserva la retirada de `notifications_for_user` (Handy 924); el cambio de upstream era sólo el adaptador. |
| `webhook.rb` | Cuota del fork y atribución (`creator`, `created_via`, `set_up_through`) de upstream. |
| `config/application.rb` | Filtros WebAuthn del fork y filtros OAuth de upstream. |
| `saas/config/storage.yml` | Servicio `S3WithDirectEndpoints` y `direct_upload_endpoint` de upstream; bucket por entorno, `ssl_verify_peer: true` y CA interna del fork (Handy 964). |
| `db/schema*.rb` | Versión de upstream; columna e índice `endpoint_digest` y `session_id` del fork, más `oauth_client_id` de upstream. |
| `Gemfile*.lock` | Unión: dependencias de RubyLLM del fork y mysql2 de upstream. `bundle install` no vuelve a resolver; `bin/bundle-drift check` en verde. |
| `my/access_tokens_controller_test.rb` | Flujo de upstream (sin redirección); se conserva `assert_includes ... "no-store"` del fork, porque `OfflineCaching` añade directivas. |
| `data_transfer/record_set_test.rb` | Se conservan los casos del fork y el caso nuevo de upstream. |

`webhooks/_webhook.json` de upstream oculta `signing_secret` sólo a una
concesión OAuth; Dédalo lee el secreto con un token personal, que lo sigue
recibiendo.

## Pruebas adaptadas

Las cuatro respuestas de autoría de cada grupo:

| Pruebas | Contrato | Regresión detectable | Cobertura previa | Seam |
|---|---|---|---|---|
| `oauth_delegate_resources_test.rb`: «a grant cannot register a push subscription» (sustituye a dos casos de upstream que esperaban 201) y helper `subscribe_push`; `personal_access_token_forms_test.rb`: «… personal access token cannot register a push subscription» (dos formas); `oauth_token_exchange_test.rb`: 403 del token delegado. Dueño: `Users::PushSubscriptionsController#create`. | Un token (personal, OAuth o delegado) no registra push: 403 y ninguna fila. | Adoptar el controlador de upstream en un merge futuro. | `push_subscriptions_controller_test.rb` sólo usa sesión; ningún caso del fork enviaba un token. | Ninguno nuevo. |
| Resto de casos push de `oauth_delegate_resources_test.rb` (limpieza al desconectar, revocar, caducar o repetir refresh; entrega con concesión viva, oscura, sólo staff, otra cuenta u otra identidad). Dueños: `Identity::AccessToken`, `Push::Subscription.deliverable_to`, `Notification::PushTarget::Web`. | Una fila con `oauth_client_id` deja de entregar y se borra con la última concesión. | Quitar `deliverable_to` de `web.rb` o la limpieza del modelo. | Sin la fila plantada, estos casos pasaban sin observar nada: `assert_not exists?` sobre una fila que el 403 nunca creó. | Ninguno. El helper crea la fila en el modelo, con una sesión viva (el `active` del fork la exige) y el cliente del token. En producción el fork no crea esa fila; el código de upstream sigue presente y se prueba igual. |
| «claiming an endpoint again hands it to whoever claimed it last» (antes «registering … registered it last»). | `claim_for` cambia de app; una sesión distinta no toma el endpoint (409, Handy 928). | Volver a reasignar desde el controlador. | El caso de upstream dependía del registro HTTP con token. | Ninguno. |
| `test/lib/saas_storage_tls_test.rb`. Dueño: `saas/config/storage.yml` y `S3WithDirectEndpointsService`. | El cliente de cargas directas también verifica la CA interna y usa su credencial propia. | Adoptar `ssl_verify_peer: false` de upstream. | Los casos del fork sólo observaban el cliente principal. | Agrega `saas/lib` al load path dentro de la prueba: el configurador requiere el adaptador por nombre y el bundle OSS no carga el engine. Sin API nueva. |

| `test/system/offline_cache_test.rb`: «PAT reveal and transfer page never enter Cache Storage». Dueño: worker y `OfflineCaching` (Handy 925). | La página que muestra un token nuevo no entra en Cache Storage. | Que el worker guarde la respuesta que muestra el token. | Mismo caso; sólo cambia dónde se lee el token. | Ninguno. Upstream muestra el token en la respuesta del POST (201, sin redirección); la prueba lee esa respuesta en vez de seguir `created.url`, que ahora es la URL del POST. |

No se retira ninguna prueba del fork. Se retira el caso de upstream «a push
subscription records its app as it's inserted, not in a second write»: probaba
el `create_with(oauth_client:)` del controlador de upstream, que el fork no
usa; el caso de 403 cubre ese controlador.

### Excepción RED y sensibilidad

La base del fork no tiene OAuth, `deliverable_to` ni el adaptador nuevo: los
casos fallarían con `NameError` o por rutas ausentes, que no es RED válido.
Alternativa: cambio temporal controlado sobre el merge, con
`users/push_subscriptions_controller.rb` y `saas/config/storage.yml` de
`08f757809`, y el comando

```
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 mise exec -- bin/rails test \
  test/lib/saas_storage_tls_test.rb test/integration/oauth_delegate_resources_test.rb \
  test/integration/personal_access_token_forms_test.rb test/integration/oauth_token_exchange_test.rb
```

Salida 1: 111 casos, 26 fallos. Fallan los casos de 403, cada caso que planta
una fila (el helper espera 403) y cinco casos TLS. Restaurados los archivos,
`git diff` no muestra cambios y el mismo comando da salida 0.

El caso de Cache Storage falló en la primera ejecución del merge
(`revealed: false`) porque el flujo cambió, no por una regresión del worker;
no hay RED histórico que reconstruir.

Las demás pruebas son las de upstream sin cambios; su RED pertenece a
upstream y no se reconstruyó.

## Validación

Entorno: `GEM_HOME`, `GEM_PATH`, `MY_RUBY_HOME`, `RUBY_VERSION`, `RUBYOPT`,
`RUBYLIB`, `BUNDLE_PATH`, `BUNDLE_WITH` y `BUNDLE_WITHOUT` retirados;
`SAAS=false`, `BUNDLE_GEMFILE=Gemfile`, Ruby 4.0.9 de mise, SQLite. Bases de
prueba recreadas con `db:drop db:create db:schema:load`.

| Comando desde `fizzy-custom/` | Resultado |
|---|---|
| Primera suite del merge, `PARALLEL_WORKERS=4 mise exec -- bin/rails test` | Salida 1; 3.017 casos, 11 fallos y 10 errores: los grupos de push y TLS descritos arriba |
| Suite final, mismo comando | Salida 0; 3.016 casos, 16.467 aserciones, sin fallos ni errores, seis omisiones |
| `PARALLEL_WORKERS=1 mise exec -- bin/rails test:system` | Primera vez salida 1: 97 casos, 2 fallos. `OfflineCacheTest` por el flujo nuevo de tokens (adaptado arriba); `CardStageNavigationTest` intermitente (pasó tres veces seguidas sin cambios). Repetido tras la adaptación: salida 0; 97 casos, 630 aserciones, sin fallos ni omisiones |
| `mise exec -- bin/rubocop -f simple` | Salida 0; 1.106 archivos, sin infracciones |
| `mise exec -- bin/bundle-drift check` | Salida 0 |
| `mise exec -- bin/bundler-audit check --update` | Salida 0; sin vulnerabilidades |
| `mise exec -- bin/importmap audit` | Salida 0 |
| `mise exec -- bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` | Salida 0; sin avisos |
| `mise exec gitleaks@8.28.0 -- bin/gitleaks-audit` | Salida 0; sin secretos |
| `mise exec -- ruby script/check_agents_docs` | Salida 0 |
| `test/setup-phases-test` | Salida 0; 26 aserciones |
| `node --experimental-vm-modules --test test/javascript/` | Salida 0 |
| `mise exec -- bash test/dev-port-test` | Primera vez 13/15 (ruta tailscale del caso «Its own tailscale route»); repetido sin cambios, 15/15. Upstream no tocó `bin/dev` ni la prueba |
| `docker build --pull --tag handy-fizzy-1712-check .` | Salida 0; incluye precompilación de assets |
| `docker run --rm --network none --env SECRET_KEY_BASE_DUMMY=1 --entrypoint /rails/bin/rails handy-fizzy-1712-check runner 'Rails.application.eager_load!; …'` | Salida 0; Ruby 4.0.9, mysql2 0.5.7, arranque de producción correcto, sin red ni datos reales |

SaaS no está habilitado en este checkout: no se ejecutan las pruebas de
`saas/test` con su engine, MySQL ni Sentry. El despliegue de esta tarjeta es
OSS/SQLite.
