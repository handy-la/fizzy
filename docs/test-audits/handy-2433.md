# Sincronización de Basecamp: Handy 2433

Base del fork: `8f136b7568761b00a4f56faa06d8a753da650388`.
Upstream: `8e3c3d1a6c9a780406b1176426ddfa1183cabd18`, 16 commits desde
`381a1d3e9` (la sincronización de Handy 2119). Upstream no avanzó antes del
fetch. Merge con segundo padre; sin cherry-pick.

## Resolución de conflictos y personalizaciones

| Archivo | Decisión |
|---|---|
| `app/models/webhook.rb` | `PERMITTED_SCHEMES` sigue en `https` (Handy 941); entra `PERMITTED_PORTS = [ 80, 443 ]` de upstream (28511c2ce) y su validación al cambiar la URL. |
| `app/models/webhook/delivery.rb` | `perform_request` rechaza HTTP (`insecure_uri`) antes que el puerto (`forbidden_port`) y que el DNS. El plazo total de `2 × ENDPOINT_TIMEOUT` del fork (Handy 2372) envuelve el `post` de upstream, que convierte una cabecera con CR suelto en `invalid_response`. Entran `Errno::EPIPE` como `destination_unreachable` y `Accept-Encoding: identity` en las cabeceras persistidas. |
| `test/models/webhook_test.rb` | Se conservan los dos casos de HTTP del fork y entran los dos de puerto de upstream, adaptados a HTTPS (abajo). |
| `Gemfile.lock` | Lado del fork (`multipart-post`, `net-http`) con msgpack 1.8.7. `bin/bundle-drift check` en verde. |

`forbidden_port` e `invalid_response` no están en `RETRY_ERRORS`: son fallos
terminales y suman un fallo consecutivo, como en upstream. `EPIPE` entra en
`destination_unreachable`, que el fork reintenta (Handy 942).

El webhook de Dédalo entra por el túnel de cloudflared en el puerto 443
(`docs/design.md` de Dédalo): el límite de puertos no lo afecta. Un webhook
guardado antes con otro puerto conserva su URL y recibe `forbidden_port` al
entregar; `deactivate` sigue funcionando (caso de upstream).

Sin conflicto, revisados a mano: `ActivitiesController` y su vista JSON
(paginación por id de evento, 772f5736c y 4dca5927b),
`Boards::InvolvementsController` (sin `format.turbo_stream`, 65a290c11) y la
configuración SaaS de `FIZZY_REVIEWER_SIGN_IN_CODES` (259c62492: sólo el
nombre de la variable en `saas/.kamal/secrets.production` y
`saas/config/deploy.production.yml`; ningún valor).

## Lexxy 1.0.4 y el saneado de Action Text

Lexxy 1.0.4 (d4033eb20) mueve `lexxy.sanitization` de
`on_load(:action_text_content)` a un `after_initialize` que corre después del
de `config/initializers/sanitization.rb`. Lexxy calcula sus listas sobre las
del fork, pero `ActionTextLinkScrubber` guarda una copia anterior: en `test` y
en `production` el scrubber perdía `data-language`, `style`, `audio` y el
resto del marcado de Lexxy (comprobado con `bin/rails runner` sobre
`ActionText::ContentHelper.scrubber`). Efecto: los bloques Mermaid se
mostraban como texto y el audio de una tarjeta publicada desaparecía.

Corrección: el initializer une las listas del scrubber con el marcado de
Lexxy (`s u video audio source embed table tbody tr th td`; `controls poster
data-language style value start`). Es el mismo marcado que el scrubber
recibía con Lexxy 1.0.1, así que el saneado vuelve a su estado anterior y no
se amplía. Regla en `CLAUDE.md` («Medios externos y saneado de Action Text»).

Pruebas: no se agrega ninguna. `test/system/mermaid_diagram_test.rb` y
`test/integration/active_storage_served_content_types_test.rb` ya detectan
la regresión (RED abajo).

## Pruebas adaptadas o nuevas del fork

Cuatro respuestas de autoría por prueba:

| Prueba y dueño | Contrato | Regresión detectable | Cobertura previa | Seam |
|---|---|---|---|---|
| `webhook_test.rb`, «validates the url port» y «a webhook saved with another port can still be deactivated» (upstream 28511c2ce); `Webhook#validate_url`, `#deactivate` | Una URL nueva o cambiada sólo usa el puerto 80 o 443; una fila antigua con otro puerto se puede desactivar. Upstream probaba `http://…:443` y `http://…:8080`; el fork rechaza HTTP antes del puerto, así que los casos usan `https://`. | Quitar la comprobación de puerto, o validarla también sin cambio de URL. | Los casos de HTTP del fork no observan el puerto. | Ninguno. |
| `webhook/delivery_test.rb`, «deliver still fails the job when the payload can't be built» (upstream 15d63199a); `Webhook::Delivery#deliver` y `#post` | Un `ArgumentError` al construir el cuerpo sigue fallando el job (`errored`); sólo el de la respuesta se convierte en `invalid_response`. Upstream hace stub del renderer del webhook cargado; el `deliver` del fork recarga la entrega y con ella el webhook, así que el stub va a `ActionController::Renderer.any_instance`. | Ampliar el `rescue ArgumentError` a todo `perform_request` o a `deliver`. | «deliver when the response has a malformed header» cubre el otro lado. | Ninguno. |
| `webhook/tls_test.rb` (Handy 941); `Webhook::Delivery#http` | Sin cambio de contrato: SNI y verificación con el nombre lógico. El servidor local escucha en un puerto aleatorio, que el límite de upstream rechaza; la URL usa ahora el puerto 443 y el `Net::HTTP.new("webhook.example.invalid", 443, nil)` esperado devuelve el cliente del puerto local. | La misma de Handy 941 (perder SNI o el certificado del nombre lógico). | — | Ninguno. |

Las otras pruebas de upstream entran sin cambios:

| Pruebas y dueño | Contrato y regresión detectable | Cobertura previa y seam |
|---|---|---|
| `delivery_test.rb`: «… something other than HTTP», «… malformed header», «asks for an uncompressed response», «refuses a port other than 80 or 443 without connecting», `EPIPE` en «… can't reach the destination»; `Webhook::Delivery` (28511c2ce, 854cf0639, 15d63199a) | Respuestas que no son HTTP, cabecera con CR, puerto no permitido: entrega cerrada con su error y un fallo consecutivo, sin excepción del job. `EPIPE` como destino inalcanzable. Pide el cuerpo sin compresión. | Sin casos previos. Sin seam. |
| `activities_controller_test.rb`: «index pages through event ids …», «… leaves out an event that moves to an inaccessible board …»; `ActivitiesController#index` (772f5736c, 4dca5927b, 605d1887f) | La página se elige por id y sólo se cargan sus eventos, otra vez por el scope accesible. Detecta volver a `preloaded` en la consulta paginada. | Sin casos previos. Sin seam. |
| `boards/involvements_controller_test.rb`: «update as turbo stream replaces the involvement frame»; `Boards::InvolvementsController#update` (65a290c11) | Un envío de Turbo recibe el HTML del frame, no 406. | Sin casos previos. Sin seam. |
| `saas/test/lib/production_secrets_test.rb` (259c62492) | Cada secreto de producción llega a `deploy.production.yml`. | No se ejecuta: el bundle SaaS necesita un repositorio privado (Handy 1394). |

No se retira ninguna prueba.

## RED

**Pruebas de upstream y adaptadas.** Exportación de la base con `git archive
8f136b7568761b00a4f56faa06d8a753da650388` en `.context/handy-2433-base` del
workspace (no es otro worktree ni el checkout fuente); se copiaron sin cambios,
desde el merge, `webhook_test.rb`, `webhook/delivery_test.rb`,
`webhook/tls_test.rb`, `activities_controller_test.rb` y
`boards/involvements_controller_test.rb`. Entorno de la validación, base de
prueba recreada, `PARALLEL_WORKERS=1`:

```
bin/rails test test/models/webhook_test.rb test/models/webhook/delivery_test.rb \
  test/models/webhook/tls_test.rb test/controllers/activities_controller_test.rb \
  test/controllers/boards/involvements_controller_test.rb
```

Salida 1: 92 casos, 6 fallos y 3 errores, todos RED por contrato:

- `validates the url port`: la base acepta `https://example.com:25/…`.
- `refuses a port other than 80 or 443`: la base no suma el fallo de puerto.
- `something other than HTTP`, `malformed header`: `EOFError` y `ArgumentError`
  salen del job (el defecto corregido).
- `can't reach the destination`: `Errno::EPIPE` sale del job.
- `asks for an uncompressed response`: sin `Accept-Encoding: identity`.
- Las dos de actividades: la consulta paginada lee `events.*`; el evento movido
  sigue en la respuesta.
- `update as turbo stream`: 406.

Sin RED (regresión): «deliver still fails the job when the payload can't be
built» y `tls_test.rb` pasan en la base, como se espera de su contrato.

El mismo comando sobre el merge: salida 0 (parte de la suite final).

**Saneado de Lexxy.** Primera `PARALLEL_WORKERS=1 bin/rails test:system`
sobre el merge, sin la corrección del initializer: salida 1, 148 casos,
14 fallos y 4 errores. Dieciséis son de `MermaidDiagramTest` (el bloque queda
como `<pre>` sin `data-language`, comprobado en el navegador). En la suite de
unidad de esa misma corrida, `ActiveStorageServedContentTypesTest#test_a_published_card's_images_and_media…`
recibe `[1, 1, 1, 0]`: falta el `audio`. Con la corrección, los mismos
archivos: salida 0, 46 casos. En la base (Lexxy 1.0.1) esas pruebas ya
pasaban.

En esa corrida fallaron también `CardDockSystemTest#test_the_dock_goes_to_the_start_of_the_last_comment…`
y `PrivateOfflineCacheTest#test_an_updated_worker…` (este último ya está
registrado como intermitente en Handy 2119). Pasaron en las corridas
siguientes; no se comprobó si el primero dependía del saneado.

## Validación

Entorno: variables de RVM y Bundler retiradas, `SAAS=false`, Ruby 4.0.9 de
mise **delante** de `/usr/bin` en el `PATH` (como en Handy 2119), SQLite.

| Comando desde `fizzy-custom/` | Resultado |
|---|---|
| Primera suite, `PARALLEL_WORKERS=4 bin/rails test` | Salida 1; 3.283 casos, 1 fallo (audio, arriba) y 3 errores (`tls_test.rb` por el puerto, adaptado arriba) |
| Suite final, mismo comando | Salida 0; 3.283 casos, 18.170 aserciones, sin fallos ni errores, cinco omisiones |
| `PARALLEL_WORKERS=1 bin/rails test:system`, final | Salida 0; 148 casos, 1.121 aserciones |
| `bin/rubocop -f simple` sobre los Ruby cambiados por el fork | Salida 0 |
| `bin/bundle-drift check` | Salida 0 |

`delivery_test.rb`, «deliver gives up when the whole request passes its total
deadline» (Handy 2372), falló una vez con 32 procesos en paralelo: 1,035 s
contra el límite de 1,0 s. Pasó tres de tres veces en serie y en las suites
completas. Ni la prueba ni el plazo cambian aquí.

SaaS no está habilitado en este checkout: no se ejecutan `saas/test` (Handy 1394).
