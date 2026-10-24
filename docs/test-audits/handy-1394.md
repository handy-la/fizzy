# Sincronización de Basecamp: Handy 1394

Base del fork: `db61d7873704e5a9414ef21d2bfaea3855e06eac`.
Upstream: `314bf8954b6fe728a6d8be40fb13161a74754c51`, 46 commits.
Se conserva el merge y su segundo padre; no se copian los commits mediante
cherry-pick. Se registró el plan de contratos antes del merge y de modificar
pruebas en `.context/handy-1394-test-plan.md` del workspace.

## Resolución de conflictos y personalizaciones

- `config/routes.rb`: se agregan los bloques de filtrado de upstream sin
  restaurar `/qr_codes`. Los QR siguen incrustados como data URI. Las rutas
  propias de push y sugerencias, y los demás endpoints del fork se conservan.
- `app/views/pwa/service_worker.js.erb`: permanece el worker del fork, que sólo
  guarda assets públicos. Se incrusta `RENDERING_VERSION` para que el cambio
  del saneador cambie los bytes del worker y provoque su actualización. Su
  activación existente espera `clearPrivateCaches()` y borra el registro
  IndexedDB antes de tomar control. No se restaura TurboOffline ni su caché de
  páginas. Los fragmentos y los ETag adoptan `v2` de upstream.
- `test/controllers/pwa_controller_test.rb`: se adapta la prueba nueva de
  versión al worker del fork. No se restaura la prueba CORS ni su helper:
  cubrían un fetch remoto retirado antes de esta tarjeta.
- Se conserva RubyLLM 2.0.0, `ruby-vips`, el filtro de campos WebAuthn, la CSP
  de medios, la franja del título, las sugerencias por Cable, el aviso de
  siguiente tarjeta, las cuotas y los trabajos de webhooks del fork.
- Ruby y las tres imágenes Docker adoptan 4.0.9. El bundle OSS conserva las
  dependencias propias. `bundle install` no vuelve a resolver el lockfile.

La primera suite del merge detectó cuatro columnas propias que upstream no
conocía. Se clasifican en `NOT_SECRET`, sin ampliar la lista de tablas filtradas
ni cambiar el comportamiento productivo: digest SHA-256 de challenge consumido,
digest SHA-256 de endpoint, revisión de sugerencia protegida además por usuario,
cuenta y acceso a la tarjeta, e identificador de lease de un job interno.
Dueños consultados: `ActionPack::Passkey::ConsumedChallenge`,
`Push::Subscription`, `CardSuggestionChannel`, `Card::SuggestionRequest`,
`Webhook::Dispatch` y `Webhook::DispatchJob`. El token de sugerencia no basta
para entrar al canal; el lease sólo tiene un consumidor interno.

## Contratos de las pruebas importadas

Cada grupo registra contrato, regresión, cobertura previa y seam. Salvo las
adaptaciones declaradas, las pruebas son las del SHA de upstream indicado.

| Pruebas y dueño | Contrato y regresión detectable | Cobertura y seam |
|---|---|---|
| `test/lib/rails_ext/active_record_sql_redaction_test.rb`; extensión SQL | La base recibe el valor original, pero logs, eventos, binds y errores no lo exponen en tablas declaradas. Detecta quitar el subscriber, cambiar su orden o filtrar sólo parte de una sentencia. EXPLAIN sigue funcionando. | No había prueba OSS de estos consumidores antes del merge. Las pruebas pasan por modelos y SQL reales; el subscriber temporal que observa el SQL ejecutado pertenece sólo a la prueba. El inventario estático es una defensa adicional ante nuevas columnas; sus cuatro clasificaciones locales describen consumidores reales. |
| `test/lib/rails_ext/action_mailer_delivered_event_without_mail_test.rb`; extensión de Action Mailer | Se entrega el correo con su código, pero sus eventos y logs no conservan el cuerpo. Detecta quitar la redacción o instalarla después de otro consumidor. | Las pruebas previas de mailers comprobaban entrega, no la redacción del evento. Usa el mailer productivo y el evento real; restaura logger y subscriber. Sin API productiva nueva para pruebas. |
| `test/helpers/rich_text_style_sanitization_test.rb`; Action Text, Loofah y crass | El contenido no conserva `position`, `top` ni `left` escondidos dentro de una URL CSS inválida. Detecta crass 1.0.7. | Las pruebas previas de medios y CSP no usan esa secuencia CSS. Observa el HTML saneado por la entrada productiva; sin seam. |
| `test/controllers/rendering_version_test.rb` y caso nuevo de `pwa_controller_test.rb`; controlador y worker | Fragmentos, ETag y script del worker cambian de versión al retirar contenido saneado con crass anterior. Detecta dejar alguna clave en `v1` o quitar la versión del worker. | La prueba PWA previa sólo observaba tipo, acceso y no-store. La nueva adapta el consumidor al worker propio. `OfflineCacheTest` y `PrivateOfflineCacheTest` conservan la comprobación real del borrado y del aislamiento de sesión. Sin seam nuevo. |
| `test/controllers/boards_controller_test.rb` y `test/models/board/entropic_test.rb`; `Board::Entropic` | Crear un tablero por HTML/JSON guarda su plazo, sin tocar el de la cuenta; el plazo inválido revierte el guardado. Detecta guardar la entropía dentro del setter, antes de tener cuenta. | La creación anterior no pasaba plazo. HTTP y modelo cubren transporte y transacción, respectivamente. Sin seam. |
| `test/models/signup/account_name_generator_test.rb`; generador de nombre | Un punto en el nombre se trata literalmente. Detecta interpolar sin `Regexp.escape`. | Los casos anteriores no usaban metacaracteres. Usa identidad y cuentas reales; sin seam. |
| `test/lib/canadian_permanent_time_test.rb`; TZInfo y bundle | Los datos vienen de la gema y mantienen los offsets nuevos en tres zonas antes y después de noviembre. Detecta volver al tzdata del sistema. | No había caso de esas zonas. Usa la API pública de TimeZone; sin seam. |
| `test/middleware/trusted_types_report_only_test.rb`; middleware CSP | Mantiene cabecera separada sólo en HTML, destino propio y muestreo. Detecta perder el URI o aplicar la política fuera de la muestra. | Amplía los casos previos de cabecera y contenido. El único doble fija el azar para observar ambos lados del umbral; la respuesta pasa por Rack::Lint. Sin seam productivo nuevo. |
| `test/models/trusted_types_violation_test.rb` y `test/controllers/trusted_types_reports_controller_test.rb`; modelo y receptor | Conserva sólo sink, ubicación y ruta; ignora texto privado, URLs completas, valores mal formados y rangos imposibles. El endpoint rechaza tipos que Rails analizaría y registraría como parámetros. | No existía receptor. Modelo y HTTP cubren privacidad del formato y entrada de red por separado. Sin seam. |
| `test/system/mermaid_diagram_test.rb`; Pele, helper y controlador de sintaxis | Mantiene SVG saneado, diálogo, fuentes y refrescos; no carga imágenes externas y adapta flujo ancho al móvil. Detecta perder `images: false`, el saneado o `maxWidth`. | Amplía la suite real de Mermaid; no agrega una segunda suite equivalente. Los helpers privados miden viewBox y retienen la promesa de fuentes del navegador. La ventana se restaura con ensure. |
| `test/models/webhook/delivery_test.rb`; entrega de webhooks | Conserva cuerpo de formulario, cabecera y contenido escapado. Detecta cambiar el formato transmitido. | Los mismos casos cambian `CGI.parse` por `URI.decode_www_form(...).to_h` para Ruby 4. No retiran aserciones ni agregan seam. |
| `saas/test/integration/credential_paths_test.rb`; rutas y logger estructurado | Filtra credenciales en rutas reales y sufijos sin ruta válida. Detecta mover un endpoint fuera del bloque de filtrado. | No había esos casos. Los helpers generan las rutas productivas. Se adapta sólo el QR retirado del fork; sin seam nuevo. |
| `saas/test/integration/structured_log_redaction_test.rb`; logger y Sentry | El log de HTTP/job, breadcrumbs, spans y errores conserva diagnóstico sin credenciales; las otras tablas conservan su SQL. Detecta filtrar sólo el log final o perder el filtro de URL/Referer. | Es la frontera SaaS que no demuestra el test OSS de notificaciones. El transporte Sentry es del proveedor; los subscribers se retiran por objeto para no quitar el filtro productivo. Sin API local nueva. |
| `saas/test/lib/queenbee_api_token_test.rb`; prepare de engine y Queenbee | Durante rotación acepta token actual y anterior, y fuera de ella no acepta uno vacío ni ajeno. Detecta perder la asignación del token anterior. | No había caso de rotación. El helper privado restaura entorno y tokens. Sin seam productivo nuevo. |
| Caso nuevo de `saas/test/lib/hotcell_image_test.rb`; Dockerfile de celda | La celda usa el mismo Ruby que la aplicación. Detecta cambiar sólo una imagen. | Amplía el inventario de propiedades de la imagen. La lectura del Dockerfile es la frontera independiente más barata para este contrato de empaquetado. Sin seam. |

## Sustituciones acotadas

| Identidad, dueño e historia | Cobertura restante y riesgo | Decisión |
|---|---|---|
| Mermaid: los dos casos de CSS de directivas inspeccionaban `<style>`; upstream `0a52a2a7c` cambia el motor a Pele. | Ahora buscan la cadena plantada en todo el SVG y mantienen aserciones de dibujo. No dependen de que el motor emita un elemento style. DOMPurify sigue filtrando SVG y los casos de `foreignObject` y atributos siguen presentes. No se pierde la defensa contra CSS inyectado. | Adoptar la sustitución de upstream. |
| Mermaid: caso «dialog fits a diagram without a viewBox». Pele ahora produce viewBox también para `info`. | El caso renombrado conserva apertura y ancho mínimo del diálogo; otro caso comprueba tamaño natural y scroll. La condición sin viewBox ya no describe la salida de este proveedor. | Conservar la prueba del tamaño con su nombre nuevo. |
| Helpers privados `hold_diagram_drawing` / `release_diagram_drawing`; antes intervenían `iframe.contentWindow.mermaid.render`. | Los dos casos de cambio de código/lenguaje mantienen la defensa contra resultados obsoletos. Ahora intervienen `document.fonts.ready`, la espera real de Pele, y restauran la propiedad. Búsqueda de consumidores limitada al archivo: ningún consumidor productivo. | Adoptar los helpers nuevos de upstream; no mantener la API del motor retirado. |
| Parte QR del caso SaaS de rutas, `7bf993293`; el fork retiró esa ruta en Handy 1203. | `QrCodeCapabilityTest` comprueba QR data URI y 404 de una URL antigua. El resto del caso SaaS sigue comprobando el token de transferencia. No existe una ruta QR cuyo filtro deba probarse. | Omitir la aserción de ruta QR importada; no restaurar una ruta sólo para pasar una prueba. |
| Caso PWA nuevo de upstream, `1bfb63e16`, esperaba `TurboOffline.serviceWorker.clearCache()`. | El fork no guarda HTML. Conserva versión y comprueba su activación propia; las dos suites offline ejercen borrado real e IndexedDB abierto. No se quita ninguna prueba del fork. | Adaptar a `clearPrivateCaches()`; no importar la prueba CORS de una función ya retirada. |

## RED histórico

Se exportó la base con `git archive` a `.context/handy-1394-base` del workspace.
Se copiaron las candidatas sin modificar desde el SHA completo de upstream.
La exportación conserva producción y dependencias de la base; no es otro
worktree ni el checkout fuente. Los datos son fixtures sintéticos.

Entorno retirado en todas las invocaciones: `GEM_HOME`, `GEM_PATH`,
`MY_RUBY_HOME`, `RUBY_VERSION`, `RUBYOPT`, `RUBYLIB`, `BUNDLE_PATH`,
`BUNDLE_WITH` y `BUNDLE_WITHOUT`. Variables: `SAAS=false`,
`BUNDLE_GEMFILE=Gemfile`, `PARALLEL_WORKERS=1`, `CI_PROGRESS_BAR=false`.
Se seleccionó `mise exec ruby@3.4.8` antes del cambio al directorio exportado.

Comando histórico desde `fizzy-custom/` (con el entorno anterior):

```ruby
# Cuerpo de ruby -e; exec recibe exactamente esta selección.
Dir.chdir("../.context/handy-1394-base")
exec("./bin/rails", "test",
  "test/controllers/boards_controller_test.rb",
  "test/models/board/entropic_test.rb",
  "test/models/signup/account_name_generator_test.rb",
  "test/helpers/rich_text_style_sanitization_test.rb",
  "test/lib/canadian_permanent_time_test.rb",
  "test/lib/rails_ext/active_record_sql_redaction_test.rb",
  "test/lib/rails_ext/action_mailer_delivered_event_without_mail_test.rb",
  "-n", "/auto.postpone|metacharacters|smuggle|permanent|magic_link.s_code|an_access_token_is_absent|delivered_mail_is_logged/")
```

Salida 1: 11 casos, 49 aserciones, 7 fallos y 1 error. Fallos por contrato:
el código aparece en log SQL y en correo, sobreviven estilos `position/top/left`,
el setter guarda antes del tablero, no se crean los tableros con plazo y el
nombre `A. Smith` recibe un ordinal que no corresponde. El error
`Account must exist` nace del setter productivo al crear el tablero nuevo:
es el fallo funcional de admisión, no un fallo de setup. Tres casos ya pasan
en la base y se conservan como cobertura de regresión.

Con la candidata Mermaid y producción de la base, mismo entorno y
`./bin/rails test test/system/mermaid_diagram_test.rb -n /on_a_phone/`:
salida 1; 1 caso, 4 aserciones, 1 fallo. La altura inline es 66 y el ancho
1346; el diagrama sigue horizontal en 390 × 844. No hay errores de importación.

Mismo entorno en la exportación,
`./bin/rails test test/lib/canadian_permanent_time_test.rb
test/middleware/trusted_types_report_only_test.rb`: salida 1; 9 casos,
14 aserciones, 4 fallos, sin errores. Se usa ZoneinfoDataSource del sistema;
Manitoba vuelve a UTC-6 en noviembre. Los dos casos nuevos del middleware
reciben el hash de opciones como URI y no cumplen destino ni muestreo.

La primera suite completa del merge, ya con Ruby 4.0.9, dio salida 1:
2.232 casos, 9.709 aserciones, un único fallo y seis omisiones. El fallo es el
inventario de las cuatro columnas locales sin clasificar. Añadir sus motivos
de uso resuelve ese fallo sin desactivar el barrido ni quitar columnas.

## Excepciones RED y límites

- Los casos nuevos de `RenderingVersionTest`, PWA, modelo/receptor Trusted
  Types y los métodos nuevos de redacción no pueden ejecutar todos sus
  caminos en la base, que carece de esas constantes, rutas y métodos. No se
  presenta un NameError como RED. Alternativa: contratos históricos de
  redacción, CSS, middleware y navegador descritos arriba, más GREEN completo.
  Quedan sin reconstruir los RED históricos de cada error SQL individual y
  de cada entrada malformada del receptor.
- SaaS no está habilitado en este checkout: no existe `tmp/saas.txt`.
  `SAAS=true BUNDLE_GEMFILE=Gemfile.saas mise exec -- bundle check`, con las
  mismas variables Ruby retiradas, falla al traer
  `basecamp/rails-structured-logging`: `Repository not found`. No es RED ni
  GREEN. Se leyeron por completo los casos nuevos, sus dueños y las rutas.
  Quedan sin ejecutar integración SaaS/MySQL, Sentry completo y rotación
  Queenbee en un engine SaaS real. El despliegue de esta tarjeta es OSS/SQLite.
- El caso PWA verifica la respuesta pública del script; las suites offline
  verifican la limpieza real. No se afirma que leer el script pruebe por sí
  solo el ciclo de vida del navegador.

## Validación

Los comandos Rails usan el entorno limpio indicado arriba, Ruby 4.0.9 de
mise, `SAAS=false`, `BUNDLE_GEMFILE=Gemfile` y SQLite. La suite de aplicación
usa cuatro workers; navegador y comprobaciones enfocadas usan uno.

| Comando desde `fizzy-custom/` | Resultado |
|---|---|
| Suite de la base, `mise exec -- bin/rails test`, Ruby 3.4.8 | Salida 0; 2.186 casos, 9.398 aserciones, seis omisiones |
| Suite final, `mise exec -- bin/rails test` | Salida 0; 2.232 casos, 9.709 aserciones, sin fallos ni errores, las mismas seis omisiones |
| `mise exec -- bin/rails test:system` | Salida 0; 96 casos, 623 aserciones, sin fallos, errores ni omisiones |
| Selección histórica de once candidatas, mismo listado de archivos y regex del RED | Salida 0; 11 casos, 71 aserciones; no se cambia ninguna candidata de esa selección |
| Ocho archivos del grupo afectado, incluidos SQL y PWA completos | Salida 0; 70 casos, 502 aserciones |
| `mise exec -- bin/rails test test/lib/canadian_permanent_time_test.rb test/middleware/trusted_types_report_only_test.rb saas/test/lib/hotcell_image_test.rb` | Salida 0; 12 casos, 23 aserciones. El caso estático de HotCell corre con bundle OSS; no demuestra arranque SaaS |
| `node --experimental-vm-modules --test test/javascript/push_subscriptions_test.mjs` | Salida 0; 13 casos |
| `test/setup-phases-test` | Salida 0; 26 aserciones |
| `mise exec -- bash test/dev-port-test` | Salida 0; 15 aserciones |
| `mise exec -- ruby script/check_agents_docs` | Salida 0; cuatro documentos |
| `mise exec -- bin/rubocop -f simple` | Salida 0; 1.001 archivos, sin infracciones |
| `mise exec -- bin/bundle-drift check` | Salida 0; bundles OSS y SaaS sincronizados |
| `mise exec -- bin/bundler-audit check --update` | Salida 0; sin vulnerabilidades |
| `mise exec -- bin/importmap audit` | Salida 0; sin paquetes vulnerables. El puente nativo y prism-mermaid no tienen versión declarada y se omiten |
| `mise exec -- bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` | Salida 0; cero avisos, seis avisos ignorados ya existentes |
| `mise exec gitleaks@8.28.0 -- bin/gitleaks-audit` | Salida 0; sin secretos detectados |
| `docker build --pull --tag handy-fizzy-1394-check .` | Salida 0; incluye precompilación de assets y los checks de certificados del Dockerfile |
| `docker run --rm --network none --env SECRET_KEY_BASE_DUMMY=1 --entrypoint /rails/bin/rails handy-fizzy-1394-check runner 'Rails.application.eager_load!; puts "Ruby: #{RUBY_VERSION}"; puts "crass: #{Gem.loaded_specs.fetch("crass").version}"; puts "Arranque de producción: correcto"'` | Salida 0; Ruby 4.0.9 y crass 1.0.8. Sin datos reales ni red. El log también muestra avisos de rutas sin controlador ya presentes en la base |

El build de comprobación produjo la imagen
`sha256:f59cc109a63fee514a66faadb4b4ea1391c99891ae294c701c6a51e6b53759d0`.
No se inició ni se sustituyó la instancia real: su reconstrucción corresponde
al canal normal después de aterrizar.

Las capturas se obtuvieron de la prueba de navegador existente «a mermaid code
block is drawn as a diagram», con un wrapper temporal de captura, no una API
productiva ni una prueba añadida al repo. Se usó David de fixtures, tema claro,
el mismo flujo de seis pasos y ventanas de 1200 × 1000 y 390 × 844. Antes:
exportación de la base; después: merge. Ambos runners terminaron con salida 0,
1 caso y 5 aserciones. Las cuatro PNG se adjuntaron a la tarjeta. No contienen
datos de clientes. El primer archivo muestra el diagrama anterior pequeño;
el móvil nuevo lo coloca en vertical con texto legible.

Los logs de trabajo quedan en `.context/handy-1394-*.log` del workspace.
Este documento conserva comandos, causas y límites para no depender de ellos
cuando se archive la tarjeta. Un último fetch antes de revisar confirmó que
upstream sigue en `314bf8954b6fe728a6d8be40fb13161a74754c51`.
