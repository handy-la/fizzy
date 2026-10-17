# Sincronización con basecamp/fizzy `27d0d2e6b`: búsqueda, Mermaid y Trusted Types

El merge de upstream `27d0d2e6be80623d492b723126f16ef3018d6981` (26 commits
desde `e2181a7c78482981ba6a7f1a0fbe3bcd187a6d3b`) sobre el fork
`05c43888ff1c17f70c2685e7ba1361e9ebe7ae02` trae la búsqueda por frase de un
término con guion, un límite de 300 búsquedas por hora por usuario con token,
diagramas Mermaid, el inventario de Trusted Types en pruebas de sistema y
actualizaciones de dependencias.

## Resolución de conflictos

- `AGENTS.md`: se conserva nuestro symlink a `CLAUDE.md`. La sección nueva de
  upstream («New third parties and personal data») pide una tarjeta en el
  tablero de Trust & Compliance de 37signals; no aplica a este fork.
- `CardsController`: se conservan `CardStageNavigation` (Handy #628) y se agrega
  `SearchRateLimiting` con `limit_searches only: :index`.
- `_remote_image.html.erb`: se conserva `remote_media_link` (Handy #922). Upstream
  pone el `alt` en un `<img>` remoto; con nuestra política no hay `<img>` remoto.
- `cards_controller_test.rb`: se conservan nuestros dos casos de medios remotos
  y se importa el caso de `alt` de un blob. El caso de upstream «remote image
  attachment with alt text» se sustituye (sección siguiente).

### Conflicto semántico: `User::Searcher` enviaba el texto sin sanear

Handy #939 cambió `build_search_relation`: llamaba a `.search(query.to_s)` antes
de `query.valid?`. `valid?` ejecuta `sanitize_terms` (`before_validation`), por
eso el índice recibía el texto original. En upstream `valid?` corre antes. Con el
saneado nuevo de upstream (espacio sin corte y de ancho cero), el texto crudo
`release notes` llegaba a FTS5 como una frase y no encontraba nada.
Corrección: `valid = query.valid?` antes de `.search`. Es el orden de upstream.

- *RED:* el árbol del merge sin esta corrección, `bin/rails test
  test/models/search_test.rb`: salida 1, 10 casos, 2 fallos («words split by a
  non-breaking space…» y «…zero-width space…», `[]` en lugar de la tarjeta).
  La consulta SQL tenía `MATCH '{title content} : "release notes"'`.
- *GREEN:* mismo comando con la corrección: 10 casos, 0 fallos.

### Saneado con letras Unicode (regresión de la corrección anterior)

`Search::Query` sanea con `\w`, que en Ruby es sólo ASCII: «revisión» quedaba
como `"revisi n"`, «año» como `"a o"` y «café» como `caf `. En la base del fork
el texto crudo llegaba al índice y esas búsquedas funcionaban; al sanear antes
(sección anterior) dejaban de funcionar. Corrección: `[[:word:]]` en lugar de
`\w` en `quote_joined_words` y `remove_invalid_search_characters`.

Caso nuevo «an accented term matches its own word» (`search_test.rb`):
- *Contrato:* «revisión», «año» y «café» encuentran su tarjeta, por
  `User#search` y por `Card.mentioning`. Dueños: `Search::Query`,
  `User::Searcher`. Frontera: índice FTS5 de SQLite.
- *Regresión:* volver a `\w` en el saneado, o sanear con una clase ASCII.
- *Cobertura:* ningún caso de `search_test.rb` ni de `searches_controller_test.rb`
  usa una letra fuera de ASCII; el tablero de Handy está en español.
- *Seam:* ninguno.
- *RED:* árbol del merge `b3e0ca7d7` (orden corregido, saneado ASCII),
  `bin/rails test test/models/search_test.rb -n "/accented/"`: salida 1, 1 fallo
  en «revisión». En la base `05c43888f` el mismo caso pasa (6 aserciones): la
  regresión era de la corrección, no del fork. *GREEN:* con `[[:word:]]`, pasa.

Caso de upstream modificado «highlight marks an accented word the sanitizer
truncated» (`mysql_sharded_test.rb`, `03f3bd012`), ahora «…whether the query
keeps or truncates it»: su precondición fijaba `caf ` como salida del saneado,
que es el defecto de arriba. Ahora exige `café`, y que el resaltado MySQL marque
`café` tanto con `café` como con `caf` (una consulta antigua). El contrato del
resaltado de upstream se conserva; sólo cambia la precondición.

## Prueba sustituida

| Campo | Evidencia |
|---|---|
| Identidad y dueño | `fizzy-custom`, `test/controllers/cards_controller_test.rb`, caso de upstream «show card with comment containing remote image attachment with alt text» (`2568389d9`, lexxy v1.0.1); `action_text/attachables/_remote_image.html.erb` |
| Fallo detectable | Exige `img[alt]` remoto: detecta un partial que pierde el `alt` |
| Consumidores | El partial lo usa Action Text al mostrar tarjetas y comentarios |
| Cobertura restante | Caso adaptado «…remote image attachment with alt text keeps the image blocked»: exige 0 `img` y el enlace con `rel~=noreferrer`. Más «saved remote media and comments require consent» y «card responses restrict media to authorized origins» |
| Historia | Upstream renderiza la imagen remota; Handy #922 la bloquea hasta una acción explícita |
| Riesgo | El contrato de upstream (mostrar el `alt` en una imagen remota) contradice nuestra política; no se pierde una defensa del fork |
| Validación | Con el partial de upstream en el árbol del merge, el caso adaptado falla (`Expected exactly 0 elements matching "action-text-attachment img", found 1`); con el nuestro pasa |
| Decisión | Sustituir |

Cuatro respuestas del caso adaptado: *contrato*, un `alt` no hace que el partial
cargue la imagen remota (dueño: el partial; frontera: HTML de `GET /cards/:id`);
*regresión*, tomar el partial de upstream en un merge futuro; *cobertura*, el
caso de consentimiento no tiene `alt`, y este es el punto donde upstream cambió
el partial; *seam*, ninguno.

## Pruebas importadas de upstream

No se cambia ninguna prueba importada, salvo la sustituida arriba.

**Límite de búsquedas** (`search_rate_limiting_test.rb`, 6 casos; `47973139b`,
`897c21038`, `6cabbeca7`).
- *Contrato:* un usuario con token tiene 300 búsquedas por hora entre
  `/cards.json?terms[]`, `/search` y el JSON de un tablero con términos; la 301
  recibe 429 con `Retry-After`; otro usuario conserva su cupo. Dueños:
  `SearchRateLimiting`, los tres controladores. Frontera: HTTP.
- *Regresión:* quitar `limit_searches` de un controlador o cambiar el `scope`.
- *Cobertura:* no había límite ni prueba de 429 en `searches_controller_test.rb`,
  `cards_controller_test.rb` o `boards_controller_test.rb`. *Seam:* ninguno nuevo.
- Uso de Dédalo en la caja: 24 a 32 búsquedas por hora el 2026-10-17 (log del
  contenedor `handy-fizzy-local-fizzy-1`), lejos de 300.

**Búsqueda por frase y separadores** (`search_test.rb`, 4 casos;
`mysql_sharded_test.rb`, «stem a query keeps each quoted phrase together»;
`cb5ef4811`, `ed4490a56`, `856cbe293`). *Contrato:* un término con guion
coincide con sus partes juntas; un espacio sin corte o de ancho cero separa
palabras; el stemmer MySQL conserva las comillas. Dueños: `Search::Query`,
`MysqlSharded::Stemming`. *Regresión:* quitar `quote_joined_words` o sanear
después de enviar (caso de arriba). *Cobertura:* «search for hyphenated strings»
sólo exige que la tarjeta aparezca, no que las demás no aparezcan; ningún caso
anterior usa un espacio sin corte o de ancho cero. *Seam:* ninguno.

**Alt de adjuntos** (`exportable_test.rb`, 1 caso; `cards_controller_test.rb`,
caso del blob; `2568389d9`). *Contrato:* la exportación y la vista conservan el
`alt` de una imagen. *Regresión:* volver a `alt: filename`. *Cobertura:* los
casos de exportación y de vista anteriores no tienen `alt`. *Seam:* ninguno.

**Trusted Types report-only** (`trusted_types_report_only_test.rb`, 3 casos;
`static_csp_test.rb`, 1 caso; `application_system_test_case.rb` y el helper
`trusted_types_violations_test_helper.rb`; `c3401a9e6` a `3739578d2`). *Contrato:* sólo en test, una cabecera report-only aparte con
`require-trusted-types-for 'script'`, sin `report-uri`, nunca en la política de
la app. *Regresión:* mezclar la directiva con la política que bloquea.
*Cobertura:* `static_csp_test.rb` sólo comprobaba la política de las páginas
estáticas; ningún caso veía una cabecera report-only. El helper sólo recoge
violaciones en las pruebas de sistema y no hace fallar una prueba. *Seam:*
`config.x.content_security_policy.trusted_types_report_only` (sólo test).

**Mermaid** (`test/system/mermaid_diagram_test.rb`, 18 casos; `839f93c0b`,
`9ff19080f`).
- *Contrato:* un bloque de código `mermaid` en una tarjeta o comentario se dibuja
  como SVG; un bloque que no compila muestra su código; una directiva no activa
  etiquetas HTML ni agrega CSS (fuente, variable de tema anidada, color mal
  formado); el SVG no conserva `data-*`, `foreignObject`, enlaces ni
  formularios; la vista ampliada abre en un diálogo y se ajusta al tamaño; un
  refresco (broadcast o página pública) conserva el diagrama y descarta uno
  dibujado para un código o lenguaje que cambió; el editor ofrece «Mermaid» una
  sola vez, también al volver con el historial. Dueños:
  `syntax_highlight_controller.js`, `helpers/mermaid_helpers.js`,
  `initializers/lexxy_mermaid.js`, `layouts/shared/_mermaid.html.erb`. Frontera:
  el navegador (Selenium).
- *Regresión:* quitar el saneado del SVG (un diagrama inyecta un enlace o un
  `data-action` de Stimulus), aceptar `htmlLabels` desde una directiva, o
  perder el diagrama en un morph de Turbo.
- *Cobertura:* no había Mermaid; ninguna prueba de sistema anterior dibuja un
  bloque de código. «does not parse shows its source» protege contra un fallo
  del dibujo que oculte el texto.
- *Seam:* ninguno; `sanitize_diagram_svg` es un helper de la prueba que llama a
  la función productiva del módulo.

**Smoke** (`test/system/smoke_test.rb`; `2568389d9`, lexxy v1.0.1). No es parte
de Trusted Types.
- «lightbox shows the alt text of the image» (nuevo). *Contrato:* el lightbox
  muestra el `alt` del adjunto (`lightbox_controller.js`). *Regresión:* el
  controlador vuelve a copiar sólo `src`. *Cobertura:* «active storage
  attachments» abre el lightbox sin `alt`. *Seam:* ninguno.
- «active storage attachments» (modificado): el pie de foto del editor pasa de
  `textarea[placeholder]` a `.attachment__caption-text`, que es el marcado de
  lexxy v1.0.1. Es la misma aserción (el nombre del archivo en el pie) sobre el
  marcado nuevo.

### RED en la base

Exportación aislada de `05c43888ff1c17f70c2685e7ba1361e9ebe7ae02` con las
pruebas del merge copiadas encima, desde `fizzy-custom/`:

```bash
FILES="test/controllers/cards_controller_test.rb test/controllers/search_rate_limiting_test.rb \
  test/integration/static_csp_test.rb test/middleware/trusted_types_report_only_test.rb \
  test/models/active_search/store_adapters/mysql_sharded_test.rb test/models/card/exportable_test.rb \
  test/models/search_test.rb"
BASE=../.context/base-05c4
rm -rf $BASE && mkdir -p $BASE && git archive 05c43888ff1c17f70c2685e7ba1361e9ebe7ae02 | tar -x -C $BASE
for f in $FILES test/application_system_test_case.rb test/test_helpers/trusted_types_violations_test_helper.rb; do
  mkdir -p "$BASE/$(dirname $f)" && cp "$f" "$BASE/$f"; done
run() {
  env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT -u RUBYLIB \
    -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
    SAAS=false BUNDLE_GEMFILE=Gemfile CI_PROGRESS_BAR=false PARALLEL_WORKERS=1 mise exec -- "$@"
}
(cd $BASE && run ./bin/rails test $FILES)
```

Sin shim: salida 1; 92 casos, 6 fallos, 9 errores. Los errores son `NameError`
de `SearchRateLimiting` y `TrustedTypesReportOnly` y `NoMethodError` de
`stem_query`: no son RED válidos. Segunda ejecución con un shim de nombres, sin
comportamiento, cargado con `sed -i '2a require
File.expand_path("../../handy-1162-red-shim.rb", __dir__)' $BASE/test/test_helper.rb`:

```ruby
module SearchRateLimiting
  extend ActiveSupport::Concern
  SEARCHES_PER_HOUR = 300
  RETRY_AFTER = 1.minute
  class_methods { def limit_searches(**) = nil }
end unless defined?(SearchRateLimiting)
class TrustedTypesReportOnly
  def initialize(app, _report_uri = nil) = @app = app
  def call(env) = @app.call(env)
end unless defined?(TrustedTypesReportOnly)
ActiveSearch::StoreAdapters::MysqlSharded.class_eval do
  def stem_query(query) = stem(query)
end
```

Resultado: salida 1; 92 casos, 13 fallos, 0 errores. Cada fallo es su contrato:
los seis casos del límite reciben 200 en lugar de 429 (o el contador no se
incrementa); los dos separadores devuelven `[]`; el `alt` de un blob no aparece
(vista y exportación); el stemmer quita las comillas (`say bc3 io 1d8b now`);
las tres pruebas del middleware y la de CSP estático no ven la cabecera
report-only.

Casos nuevos que pasan en la base: «a hyphenated term matches its parts
together» y «a quoted phrase matches its words together» (en el fork, el texto
crudo llegaba a FTS5, que trata el guion y las comillas como frase), y el caso
adaptado de imagen remota, cuya sensibilidad se demuestra arriba.

### RED de las pruebas de sistema

Misma exportación, con `test/system/mermaid_diagram_test.rb`,
`test/system/smoke_test.rb`, `test/application_system_test_case.rb` y el helper
de Trusted Types copiados, sin shim:

```bash
(cd $BASE && run ./bin/rails test test/system/mermaid_diagram_test.rb test/system/smoke_test.rb)
```

Salida 1; 24 casos, 14 fallos, 5 errores. Mermaid: 17 de 18 casos en rojo; no
aparece `.mermaid-diagram svg`, ni el botón «Expand diagram», ni la opción
«Mermaid» en el selector. Esos `ElementNotFound` son la función ausente, no un
nombre que falta. Smoke: «lightbox shows the alt text» (sin `alt`) y «active
storage attachments» (sin `.attachment__caption-text`, lexxy anterior).

Excepción RED: «diagram SVG loses HTML labels and data attributes» termina con
`ScriptTimeoutError` en la base, porque importa `helpers/mermaid_helpers`, que
no existe allí. No es un RED válido. El contrato (el SVG no conserva
`foreignObject`, enlaces, formularios ni `data-*`) tiene RED de comportamiento
en «a drawn diagram has no data attributes» y «a drawn journey diagram has no
HTML labels». Riesgo sin probar: un SVG escrito a mano fuera de lo que
Mermaid genera; lo cubre el GREEN de este caso en el merge.

Pasa en la base: «a mermaid code block that does not parse shows its source»
(sin Mermaid, todo bloque muestra su código).

## Validación final

Árbol del merge, Ruby 3.4.8 de mise, `SAAS=false BUNDLE_GEMFILE=Gemfile`:

- `bin/rails test`: 2180 casos, 0 fallos, 0 errores, 6 omitidos.
- `PARALLEL_WORKERS=1 bin/rails test:system`, 83 casos, tres ejecuciones con la
  máquina cargada (carga media 63 en 32 núcleos): 1, 1 y 4 casos en rojo, cada
  vez en clases distintas (`PrivateOfflineCacheTest`, `CardRefreshTest`,
  `AiSuggestionSystemTest`, `OfflineCacheTest`, `MagicLinkSubmissionTest`), por
  tiempo agotado o una espera del navegador. Cada clase pasa sola en el merge
  (`card_refresh` 3 de 3; `private_offline_cache` 2 de 3, como en la base; las
  demás 1 de 1). La base `05c43888f` también falla
  de forma intermitente: `PrivateOfflineCacheTest` 1 de 4 sola y 1 en su suite
  completa. Mermaid y smoke pasan en todas las ejecuciones del merge.
- Con trabajadores en paralelo, las pruebas de sistema fallan al abrir el
  puerto de Puma; por eso se usa un trabajador, como en `handy-907.md`.

No verificado: las pruebas SaaS (`SAAS=true`) y MySQL.
