# Sincronización de Basecamp: Handy 2119

Base del fork: `9823854be374e2316977457c0c0ef222eb0b74d0`.
Upstream: `381a1d3e9db98cf99ad930f44dabe029d45cb20e`, 60 commits (26 en la
primera línea de padres). La tarjeta pedía hasta `0d5fbef0c`; upstream avanzó
12 commits antes del fetch y entran también (límite aprobado en la tarjeta:
la punta que había al hacer el fetch). Merge con segundo padre; sin cherry-pick.

## Resolución de conflictos y personalizaciones

| Archivo | Decisión |
|---|---|
| `application_controller.rb` | `RENDERING_VERSION = "v3"`, `browser_versions_enforced` y `allow_any_user_agent` de upstream; `OfflineCaching` y `rescue_from Storage::QuotaExceeded` del fork. |
| `account/data_import_job.rb` | Política del fork (tres reanudaciones, `limits_concurrency` por identidad, `after_discard` que marca el fallo, `TRANSIENT_ERRORS`, Handy 932/936) con `report: true` de upstream en `discard_on`. |
| `account/data_transfer/record_set.rb` | `load` del fork (objeto JSON con UTF-8 válido, Handy 932); es más estricto que el de upstream. `INVALID_DATA_ERRORS` de upstream entra sin conflicto. |
| `record_set_test.rb` | Se conservan los casos del fork y los nuevos de upstream. |

`RENDERING_VERSION` pasa a `"v3"`. El service worker interpola la constante
(`pwa/service_worker.js.erb`), así que sus bytes cambian y la activación borra
las cachés privadas anteriores (Handy 1394); `pwa_controller_test.rb` lo
comprueba.

Archivos que ambos lados cambiaron y Git unió solo, revisados a mano:
`active_storage_authorization.rb` (upstream retira la lista de tipos peligrosos,
sustituida por `active_storage_serve_unknown_types_as_binary.rb`; quedan los
controles de cuenta activa del fork, Handy 784), `webhook/delivery.rb`,
`push/subscription.rb`, `account/import.rb`, `account_record_set.rb` y los
lockfiles (`bin/bundle-drift check` en verde; `bundle install` no los cambia).

## Pruebas adaptadas

Cuatro respuestas de autoría por grupo:

| Pruebas | Contrato | Regresión detectable | Cobertura previa | Seam |
|---|---|---|---|---|
| `active_storage_authorization_test.rb`: cuatro casos de cuenta cancelada (Handy 784) en su paso por `rails_storage_proxy_path`; `active_storage_representation_admission_test.rb`: «a permanent failure … 422» en su paso proxy. Dueño: `lib/rails_ext/active_storage_proxy_disabled.rb` y `ActiveStorage::Authorize`. | Las rutas proxy no sirven nada a nadie: 404 antes de buscar el blob (upstream e9291fbca). El paso por la ruta de redirección sigue esperando 403 o el login. | Quitar el `prepend_before_action` del archivo de upstream: la ruta vuelve a 403/302/200/422. | Upstream agrega casos 404 para usuario con acceso y blob público; los casos del fork cubren cuenta cancelada, export y representaciones. | Ninguno. |
| `webhook/delivery_test.rb`: «deliver when the network can't reach the destination» (caso de upstream). Dueño: `Webhook::Delivery#deliver`. | `ENETUNREACH`, `EADDRNOTAVAIL` y `EAFNOSUPPORT` quedan como `destination_unreachable`. En el fork ese error se reintenta (Handy 942): la entrega sigue `pending` y no suma un fallo consecutivo; upstream la cierra y suma uno. | Quitar esos errores del `rescue`: la excepción sale del job. | «connection is refused» cubre `ECONNREFUSED`, no estos tres. | Ninguno. |
| `public/boards_controller_test.rb`: los dos casos de caché (upstream 795a07f0a). Dueño: `OfflineCaching` y `Public::BaseController`. | El tablero público no entra en ninguna caché, con sesión o sin ella: `OfflineCaching` (Handy 925) marca `no-store` toda página fuera de su lista, y anula el `public` de upstream. | Agregar el tablero público a la lista offline o quitar el `no-store`. | Ninguna prueba del fork observaba la cabecera en esta página. | Ninguno. |
| `test/system/private_offline_cache_test.rb`: «revoking a session cannot expose a card or attachment offline». Dueño: worker y `OfflineCaching`. | Después de revocar la sesión, ni la tarjeta ni el adjunto salen de la caché offline. Pide el adjunto por `rails_blob_path` (redirección), la única ruta que sirve archivos ahora. | Que el worker guarde la respuesta del adjunto. | Mismo caso; sólo cambia la ruta del adjunto. | Ninguno. |

No se retira ninguna prueba **del fork**. Upstream retira o sustituye casos
suyos; sus fichas están en «Pruebas retiradas por upstream», abajo.

## Pruebas importadas de upstream

Upstream agrega o cambia 48 archivos bajo `test/` y `saas/test/` entre
`9823854be` y `381a1d3e9` (`git diff --name-status -M HEAD^1 HEAD -- test saas/test`).
Salvo las cinco adaptaciones de arriba, entran sin cambios. Ninguna agrega un
seam productivo sólo para pruebas: los helpers que cambian
(`test/test_helpers/oauth_availability_test_helper.rb`,
`oauth_audit_test_helper.rb`) son de test y restauran la configuración que
tocan. Cuatro respuestas por grupo (el dueño va en la primera columna):

| Pruebas y dueño | Contrato y regresión detectable | Cobertura previa y seam |
|---|---|---|
| `test/integration/active_storage_served_content_types_test.rb`; `lib/rails_ext/active_storage_serve_unknown_types_as_binary.rb` (f80dc4be4) | Sólo los tipos de la lista se sirven como declarados; cualquier otro, una lista de tipos, parámetros, mayúsculas o caracteres de control salen como `application/octet-stream`. Detecta volver a la lista de tipos peligrosos. | La lista anterior (`DANGEROUS_INLINE_MEDIA_TYPE`) sólo cubría HTML, SVG y XML. Sin seam. RED abajo. |
| Casos 404 de `active_storage_authorization_test.rb` y `pagination_blob_html_xss_test.rb`; `lib/rails_ext/active_storage_proxy_disabled.rb` (e9291fbca) | Las rutas proxy dan 404 a todos. Detecta quitar el `prepend_before_action`. | Igual que las adaptaciones de arriba. Sin seam. RED abajo. |
| `test/helpers/pagination_helper_test.rb`, `test/integration/pagination_links_test.rb`, caso de búsqueda en `searches_controller_test.rb`; `PaginationHelper` (f0b9ea162, 73085b16f) | El enlace a la página siguiente se queda en la ruta de la página, conserva sus filtros y no acepta claves de control (`script_name`, `use_route`, `format`) ni parámetros de formulario de la consulta. Detecta volver a `url_for(request.query_parameters…)`. | Los casos previos sólo filtraban unas claves; los de ruta no existían. Sin seam. RED abajo. |
| `test/controllers/activities_controller_test.rb` (casos de caché), `test/lib/rails_ext/jbuilder_dependency_tracker_test.rb`; `ActivitiesController` y el tracker de Jbuilder (a3fe5ba7b) | El feed se sirve con una lectura de caché por página y se lee igual para todos; el digest de un fragmento JSON incluye sus partials. Detecta perder el `cache` del feed o el tracker. | Sin casos previos de caché del feed. El tracker es un archivo nuevo de `lib/rails_ext`, cargado en producción. RED abajo. |
| `test/controllers/rendering_version_test.rb`; `ApplicationController::RENDERING_VERSION` (8a1cf1ad9) | La versión pasó a `v3` (loofah 2.25.2). Detecta un merge que la deje atrás. | Sustituye al caso `v2`. Sin seam. RED abajo. |
| `test/lib/rails_ext/action_text_content_unrecognized_attachments_test.rb`, caso de `test/models/concerns/mentions_test.rb`; `lib/rails_ext/action_text_content_unrecognized_attachments.rb` (3cc736b0c) | Un adjunto de Action Text sin atributos reconocidos se conserva y se muestra; las menciones lo ignoran. Detecta quitar el parche. El caso «the upstream implementation … still needs replacing» falla si Rails cambia el método que el parche sustituye. | Sin casos previos. Sin seam. RED abajo. |
| `test/models/webhook/delivery_test.rb` (adaptado arriba); `Webhook::Delivery` (4bd597975) | Ver adaptaciones. | RED abajo. |
| Importación: casos nuevos de `record_set_test.rb`, `import_test.rb`, `join_code_test.rb`, `data_import_job_test.rb`; `RecordSet#import`, `AccountRecordSet`, `Account::JoinCode#import`/`#reset`, `Account::Import#create_missing_webhook_delinquency_trackers`, `DataImportJob` (cea317ca0, 4e5bd82c1, cf4aa81db, 148cadd33, 48094e93a, 40c9fb876, 2de1de32b) | Datos que no caben en una columna o no validan fallan como `IntegrityError`; un error de base de datos transitorio sigue reintentándose; los límites de join code se acotan y deben ser enteros; un webhook importado recibe su tracker; un descarte se reporta una vez. Detecta quitar `INVALID_DATA_ERRORS`, `cap_usage_limit`, la comprobación de enteros, el tracker o `report: true`. | Los casos del fork cubrían JSON y UTF-8, no columnas ni join codes. Sin seam. RED abajo. |
| `test/models/column_limits_test.rb`; lectura de límites SQLite (c95f76f47) | Los límites salen de `options[:limit]` en Rails 8b06b0eb. | El caso existía; cambia con Rails edge. Sin RED: depende de la versión de Rails, no del código del fork. |
| `test/controllers/public/boards_controller_test.rb` (adaptado arriba) | Ver adaptaciones. | Sin RED (el `no-store` es anterior). |
| `test/system/board_scroll_test.rb`; `navigable_list_controller.js`, `card_hotkeys_controller.js` (e446e8149, 93587bd08, b0aaaec28, 808b89a9a) | El hover y el clic en una columna no desplazan el tablero; Tab y las flechas sí muestran la tarjeta elegida. Detecta volver al `scrollIntoView` en hover. | Sin casos previos de scroll. Sin seam. RED abajo. |
| `test/tasks/oauth_provision_first_party_clients_task_test.rb` («a dry run prints each client's changes and writes nothing», «a dry run of a converged install changes nothing», «DRY_RUN=0 converges») y `test/models/oauth/first_party_clients_test.rb` («a plan shows what a converge would change, and writes nothing», «a plan refuses what a converge would refuse», los dos casos de staging, «each hosted client_id names one resource»); `lib/tasks/oauth.rake` y `Oauth::FirstPartyClients.plan` (9a30a7727) | Con `DRY_RUN=1` la tarea `oauth:provision_first_party_clients` imprime lo que cambiaría cada cliente y no escribe nada; `DRY_RUN=0` converge como antes. `plan` construye los mismos clientes que `provision!` sin guardarlos y rechaza lo mismo. El registro incluye el cliente MCP de staging. Regresión detectable: que la tarea ignore `DRY_RUN` y escriba, que `plan` guarde, o que el registro pierda staging. | La tarea ya existía; ningún caso previo probaba una simulación. Consumidor productivo de `plan`: sólo la tarea (`lib/tasks/oauth.rake`). Sin seam sólo para pruebas. RED abajo. |
| OAuth: `oauth_user_agents_test.rb`, `oauth_response_headers_test.rb`, `oauth_dcr_redirects_test.rb`, `oauth_error_pages_test.rb`, `oauth_connected_apps_preview_test.rb`, `oauth_consent_screen_test.rb`, `oauth_flow_test.rb`, `test/models/oauth/*`, `test/helpers/oauth_helper_test.rb`, `test/controllers/my/connected_apps_controller_test.rb`, `test/tasks/oauth_provision_first_party_clients_task_test.rb`, `test/system/oauth_consent_test.rb` y los cambios menores de otros archivos `oauth_*`, `personal_access_token_forms_test.rb`, `my/access_tokens_controller_test.rb`, `identity/access_token_test.rb`; servidor OAuth (d5814f5fd, ad2106efd, f71ac37b8, 37363bb34, 234a58bd7, b09bad3aa, 9a30a7727) | Consentimiento aprobado desde el navegador y clientes OAuth sin 406 por user agent; pantallas de consentimiento, apps conectadas y errores en palabras simples; registro dinámico con cualquier callback https que no sea nuestro; puerta `CONNECTED_APPS_PREVIEW` con revisores; `expires_in` con la vida completa del token; cliente MCP de staging. | La API cambia de nombre o no existe en la base (excepción RED abajo). Sin seam productivo nuevo. |
| `saas/test/**` (tres archivos) | Reviewer de la puerta renombrada, `Forwarded` descartado detrás de True-Client-IP, proxy 404 en SaaS. | No se ejecutan: el bundle SaaS necesita el repositorio privado `rails-structured-logging` (Handy 1394). |

### RED histórico de las pruebas importadas

Exportación limpia de la base con `git archive 9823854be` en
`.context/handy-2119-base` del workspace; se copiaron sin cambios, desde el
merge, los archivos listados en cada comando. Entorno de la validación, bases
recreadas, `PARALLEL_WORKERS=1`, desde la exportación.

**Grupo OSS (20 archivos):**

```
bin/rails test test/controllers/activities_controller_test.rb test/controllers/rendering_version_test.rb \
  test/controllers/searches_controller_test.rb test/helpers/pagination_helper_test.rb \
  test/integration/active_storage_served_content_types_test.rb test/integration/pagination_blob_html_xss_test.rb \
  test/integration/pagination_links_test.rb test/jobs/account/data_import_job_test.rb \
  test/lib/rails_ext/action_text_content_unrecognized_attachments_test.rb \
  test/lib/rails_ext/jbuilder_dependency_tracker_test.rb test/models/account/data_transfer/record_set_test.rb \
  test/models/account/import_test.rb test/models/account/join_code_test.rb test/models/column_limits_test.rb \
  test/models/concerns/mentions_test.rb test/models/identity/access_token_test.rb \
  test/controllers/public/boards_controller_test.rb test/models/webhook/delivery_test.rb \
  test/integration/active_storage_authorization_test.rb test/integration/active_storage_representation_admission_test.rb
```

Salida 1: 341 casos, 43 fallos y 9 errores.

- RED por contrato (49): seis casos de tipos servidos como declarados
  (`text/javascript`, `text/plain`, una lista de tipos); nueve casos proxy con 403, 302,
  200 o 422 en vez de 404; quince casos de paginación (enlace fuera de su ruta o
  con `secret`/`script_name` de la consulta), más el de búsqueda; dos de caché del
  feed y el digest JSON; `RENDERING_VERSION` en `v2`; cuatro importaciones con
  datos inválidos que no fallan como inválidas, el join code no entero
  aceptado, el tracker que falta y el descarte sin reporte; dos join codes por
  encima del máximo que lanzan `RecordInvalid` (el defecto corregido); tres
  adjuntos de Action Text sin atributos que lanzan `NoMethodError` en
  `mentions.rb` o en la vista (el defecto corregido) y el caso que vigila el
  método sustituido; `ENETUNREACH` sin capturar (el defecto corregido).
- Sin RED válido (3): los casos de `issued_at` en `identity/access_token_test.rb`
  (`NoMethodError`: el método no existe en la base).

El mismo comando sobre el merge: salida 0 (parte de la suite final).

**Grupo OAuth (12 archivos de prueba y los dos helpers):** mismo procedimiento
con `oauth_user_agents_test.rb`, `oauth_response_headers_test.rb`,
`oauth_dcr_redirects_test.rb`, `oauth_error_pages_test.rb`,
`oauth_connected_apps_preview_test.rb`, `test/models/oauth/{client,availability,first_party_clients}_test.rb`,
`oauth_flow_test.rb`, `oauth_consent_screen_test.rb`, `oauth_helper_test.rb`,
`oauth_provision_first_party_clients_task_test.rb`. Salida 1: 292 casos,
41 fallos y 19 errores. Los errores son API ausente o renombrada
(`reviewer_ids_from`, `OAUTH_ERROR_MESSAGES`, `UNKNOWN_CLIENT_MESSAGE`,
`connected_apps_preview_from`, `dcr_own_redirect_host?`, …): no son RED. Los
fallos mezclan contrato (406 a un cliente OAuth por user agent, callbacks
https fuera de la lista rechazados, `expires_in` incompleto) con textos y
nombres de la puerta que cambiaron.

En ese mismo grupo, RED por la causa correcta de la simulación: «a dry run
prints each client's changes and writes nothing» falla con
``Oauth::Client.order(:client_id).map(&:attributes)` changed`` (la tarea de la
base ignora `DRY_RUN` y converge), y «a dry run of a converged install changes
nothing» recibe `converged` en vez de `unchanged`. Los dos casos de staging
fallan con `RecordNotFound`: la base no registra ese cliente (contrato). Los
dos casos de `plan` no son RED (`NoMethodError`: el método no existe en la
base); la tarea, su único consumidor, sí tiene RED. «DRY_RUN=0 converges» pasa
en la base: regresión.

**Sistema:** `bin/rails test test/system/board_scroll_test.rb` con el archivo
copiado. Salida 1: 4 casos, 3 fallos (hover desplaza el tablero; el clic en el
encabezado o en el espacio vacío de una columna vuelve a la última tarjeta
con hover). El caso de Tab ya pasaba: regresión.

### Excepciones RED

- OAuth: igual que en Handy 1712, el dueño cambia de nombre o no existe en la
  base, y un `NameError` o `NoMethodError` no es RED. No se separó cada fallo
  de contrato de cada cambio de texto. Contrato aún comprobable: la suite
  GREEN del merge. Riesgo sin probar aquí: ninguno propio del fork; el
  servidor OAuth es código de upstream y sigue apagado en la caja salvo con
  `OAUTH_ACCEPTANCE_ENABLED=true`.
- `issued_at`: mismo motivo; lo cubre la suite GREEN.
- `column_limits_test.rb`: depende de la versión de Rails, no de un cambio del
  fork.
- SaaS: no ejecutable sin el repositorio privado (Handy 1394).

## Pruebas retiradas por upstream

Casos de la base que ya no existen en el merge (`git diff -M HEAD^1 HEAD`,
líneas `test "…"` quitadas sin un caso del mismo nombre). Ninguno es del fork.
Historia: el commit de upstream que los quita (columna «Dueño»). Validación de
cada fila: la suite final del merge, salida 0.

| Casos retirados | Dueño y por qué | Cobertura restante | Riesgo y decisión |
|---|---|---|---|
| `oauth_dcr_redirect_allowlist_test.rb` completo («registration accepts https only on an allowed host», «one unallowed host refuses the whole registration», «registration refuses https callbacks on hosts 37signals runs», «with no allowed hosts…», los tres de app schemes y loopback, «a client registered before its host left the allowlist still authorizes») y en `oauth/client_test.rb` y `my/connected_apps_controller_test.rb` los casos de la lista de hosts | `Oauth::Client` de registro dinámico; 37363bb34 retira la lista de hosts permitidos: el contrato dejó de existir | `oauth_dcr_redirects_test.rb`: https en cualquier host que no corremos, rechazo de http, fragmentos y userinfo, «one refused callback refuses the whole registration», «refuses https callbacks on hosts we run», y los tres casos de app schemes y loopback sin cambios | Se pierde sólo la lista, que upstream retiró. Sustituida. |
| Casos «staff only» de `oauth_staff_only_test.rb`, `oauth/availability_test.rb`, `oauth_delegate_resources_test.rb`, `oauth_token_exchange_test.rb` («anyone else is told OAuth is staff only…», «admits everyone unless staff only», «staff only must be exactly true», «the staff gate admits a reviewer…», «admits whoever an extension admits beyond staff…», push y canje con la puerta) | `Oauth::Availability`; 234a58bd7 renombra la puerta a `CONNECTED_APPS_PREVIEW` | Los mismos contratos con el nombre nuevo en `oauth_connected_apps_preview_test.rb` y `availability_test.rb` («admits everyone unless connecting apps is in preview», «the preview must be exactly true», «admits whoever an extension admits as a reviewer…»), y la variable antigua todavía se lee | Renombre. Sustituida. |
| Textos de consentimiento y apps conectadas («a trusted app is known by its name…», «a self-registered web app goes by its callback's host…», «a self-registered app on this device is named as one», «a registered app is identified by its name», «a self-registered app is identified by its callback's host, port included…», «a redirect's host reads in lowercase…», «consent names a self-registered redirect's port…», «read's description names the people…», «index names every remote host … not just the first») | `OauthHelper` y vistas de OAuth; ad2106efd y f71ac37b8 rediseñan las pantallas | `oauth_helper_test.rb` («a callback's host reads as a browser reads it, port included…», destinos, niveles de acceso), `connected_apps_controller_test.rb` («index names every remote host … and this device beside them»), `oauth_consent_screen_test.rb` | Cambia el texto, no el dato. Sustituida. |
| Paginación: «next-page link does not honor an attacker-supplied script_name», «… original_script_name», «… other url_for control options», «next-page link preserves ordinary filter params» | `PaginationHelper`; f0b9ea162 deja de pasar la consulta a `url_for` | `pagination_helper_test.rb`: «keeps to its own route when the query names #{option}» (incluye `script_name` y `original_script_name`), «keeps the query», «leaves out form params»; `pagination_links_test.rb` | El ataque ya no tiene entrada: la ruta no sale de la consulta. Sustituida. |
| Proxy con `Cache-Control` público o privado (cuatro casos de `active_storage_authorization_test.rb`) y «the proxy route answers 422 too» de `saas/test/integration/unprocessable_representation_test.rb` | `ActiveStorage::Authorize#http_cache_forever` en las rutas proxy; e9291fbca cierra esas rutas | Casos 404 de upstream y del fork (arriba). En Rails sólo los dos controladores proxy llaman a `http_cache_forever`, así que la sobrescritura del fork ya no tiene ruta que la use. El 422 de la ruta de redirección sigue en `active_storage_representation_admission_test.rb` | Una ruta cerrada no tiene caché que probar. Retirada. |
| «fragments and page ETags have moved past what was rendered under crass 1.0.7» | `RENDERING_VERSION`; 8a1cf1ad9 | El caso `v3` de `rendering_version_test.rb` | Sustituida. |

### RED

Exportación de la base con `git archive 9823854be` en `.context/handy-2119-base`
del workspace (no es otro worktree ni el checkout fuente), con los cuatro
archivos de integración adaptados copiados sin cambios. Entorno de la
validación, bases recreadas, `PARALLEL_WORKERS=1`:

```
bin/rails test test/integration/active_storage_authorization_test.rb \
  test/integration/active_storage_representation_admission_test.rb \
  test/models/webhook/delivery_test.rb test/controllers/public/boards_controller_test.rb
```

Salida 1: 88 casos, 9 fallos y 1 error.

- RED por contrato: los siete casos proxy (cinco del fork, dos de upstream)
  reciben 403, 302, 200 o 422 donde se espera 404; el caso de 422 recibe 422
  en su paso proxy. El caso de red inalcanzable sale con
  `Errno::ENETUNREACH` sin capturar: es el defecto que corrige upstream, no
  una API ausente.
- Sin RED (regresión): los dos casos de caché pública ya pasaban en la base,
  porque el `no-store` del fork es anterior.
- La prueba de sistema no se ejecutó en la base: allí la ruta proxy todavía
  sirve el adjunto, así que el cambio de ruta no tiene RED. Su contrato
  (nada offline tras revocar) es el mismo de Handy 925.

El mismo comando sobre el merge: salida 0, 88 casos.

## Validación

Entorno: variables de RVM y Bundler retiradas, `SAAS=false`,
`BUNDLE_GEMFILE=Gemfile`, Ruby 4.0.9 de mise **delante** de `/usr/bin` en el
`PATH` (`mise exec` lo dejaba detrás y `bin/rails` tomaba Ruby 3.4 del sistema),
SQLite, bases de prueba recreadas.

| Comando desde `fizzy-custom/` | Resultado |
|---|---|
| Primera suite, `PARALLEL_WORKERS=4 bin/rails test` | Salida 1; 3.140 casos, 8 fallos: los grupos adaptados arriba |
| Suite final, mismo comando | Salida 0; 3.140 casos, 17.525 aserciones, sin fallos ni errores, seis omisiones |
| `PARALLEL_WORKERS=1 bin/rails test:system` | Primera vez salida 1: 105 casos, 1 fallo (`PrivateOfflineCacheTest`, ruta proxy; adaptado arriba). Segunda: 1 fallo y 1 error intermitentes (abajo). Final sobre el commit: salida 0; 105 casos, 682 aserciones, sin fallos ni omisiones |
| `bin/rubocop -f simple`, `bin/bundle-drift check`, `bin/bundler-audit check --update`, `bin/importmap audit`, `bin/brakeman …`, `mise exec gitleaks@8.28.0 -- bin/gitleaks-audit`, `script/check_agents_docs`, `test/setup-phases-test`, `node --experimental-vm-modules --test test/javascript/` | Salida 0 cada uno |
| `bash test/dev-port-test` | Primera vez 13/15 (ruta de tailnet, como en Handy 1712); repetido sin cambios, 15/15. Upstream no tocó `bin/dev` ni la prueba |

`delivery_test.rb`, caso de red inalcanzable: las tres iteraciones crean
entregas del mismo webhook y evento con el reloj congelado, y en el fork cada
una queda `pending`. Una entrega pendiente con un id menor retiene a la
siguiente (`Webhook::Delivery#earlier_delivery_pending?`). No se reprodujo
(0 fallos en 30 corridas; la comprobación dio `false` en las tres
iteraciones), pero cada iteración ahora borra su entrega, como el caso vecino
«retry 530 and 500». La retención de producción no cambia.

Intermitencias vistas, sin relación con el merge:

- `ActiveStorageRepresentationAdmissionTest#test_one_identity_is_limited…`
  falló una vez en tres suites: el contador usa una ventana fija de un minuto
  (`Time.current.to_i / 1.minute`) y la prueba no congela el reloj, así que
  falla si cruza el cambio de minuto. Ni la prueba ni el contador cambian aquí.
- `PrivateOfflineCacheTest#test_passkey_login_clears…` también falla en la
  base (1 de 3 corridas aisladas, contra 1 de 3 en el merge). La captura
  muestra `My::TimezonesController#show`: después de `Session.delete_all`, el
  formulario automático de zona horaria (`layouts/shared/_time_zone`) hace un
  PUT sin sesión, `request_authentication` guarda esa URL como destino de
  regreso y el login con passkey termina en un GET que no existe.
- `PrivateOfflineCacheTest#test_an_updated_worker…` dio una vez
  `ScriptTimeoutError` en la suite de sistema y pasó en las demás corridas.

SaaS no está habilitado en este checkout: no se ejecutan `saas/test` (Handy 1394).
