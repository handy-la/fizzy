# Copiar bloques de código — Handy 2272

## Autoría antes de editar pruebas

Base del fork: `ace964e2b989797bc35097ff7c381cf33cf5e917`.

- **Contrato:** cada bloque de descripción o comentario entrega al portapapeles
  sólo su texto exacto, conserva espacios y saltos, confirma el éxito temporal
  y comunica el rechazo. Se puede activar con teclado y touch. La decoración
  no llega al editor ni al HTML guardado. Dueño: vistas de contenido de tarjetas,
  comentarios y contenido público; frontera: navegador, contenido guardado y
  Clipboard API.
- **Regresión:** copiar el contenedor y mezclar botones u otros bloques, usar
  `trim`, anunciar éxito tras un rechazo, duplicar controles al navegar o
  refrescar, o insertar controles en Lexxy editable.
- **Cobertura:** `code_block_styling_test.rb` protege el fondo e inline code;
  `comment_input_test.rb` protege el envío del editor;
  `mermaid_diagram_test.rb` cubre render y actualización de diagramas. Ninguna
  comprueba el portapapeles, sus errores ni la decoración de bloques ordinarios.
  Se agrega `code_block_copy_test.rb` con seis casos de estos contratos.
- **Seam:** ninguno nuevo. Las pruebas entran por tarjetas y comentarios reales.
  Un sustituto de `navigator.clipboard.writeText` sólo permite provocar rechazo
  o ausencia de API; el caso de copia exacta usa el portapapeles real de Chrome.
  CDP emula entrada touch. Las actualizaciones usan Cable/Turbo. El driver local
  del archivo declara un puntero de escritorio en Linux headless; el caso touch
  lo cambia y comprueba la media query sin hover. El navegador se cierra después
  del registro heredado de Trusted Types para aislar la emulación.

## RED y GREEN

Exportación aislada de la base mediante `git archive` en
`.context/fizzy-red-final/`, con la candidata final copiada en `test/system/`.
No se modificó el checkout de origen ni otro worktree.

En ambos directorios (`fizzy-custom/` para GREEN y la exportación para RED):

```bash
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u RUBYLIB \
  -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  PATH="/home/hermes/.local/share/mise/installs/ruby/4.0.9/bin:$PATH" \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  bin/rails test test/system/code_block_copy_test.rb
```

- **RED:** salida 1; 6 casos, 12 aserciones, 2 fallos y 4 errores. Los seis
  casos fallan por falta de `.code-block` o de sus botones, incluido el caso que
  guarda el comentario editado. No hay fallos de arranque, importación o fixtures.
  Log local: `.context/handy-2272-red-final.log`.
- **GREEN:** salida 0; 6 casos, 56 aserciones, sin fallos ni errores.
  Log local: `.context/handy-2272-green-final.log`.
- Se conserva la cobertura existente de estilo, comentarios y Mermaid. No se
  retiraron pruebas ni puntos de acceso usados por pruebas.

El caso exacto usa comillas simples y dobles al final, backticks, barras,
operadores, Unicode, un tabulador real, espacios finales y líneas vacías;
comprueba un bloque resaltado y bloques con y sin `<code>` interior. Los otros
casos verifican el mensaje de error, el cambio temporal de etiqueta, el recorrido
por Tab y activación con Enter, selección manual, un toque CDP a 390 px,
historial Turbo, refresco real de descripción y alta/edición de comentarios.

## Decisión de integración

El controlador se conecta sólo a las vistas de lectura, junto a
`syntax-highlight`. El layout general de Action Text también interviene en
`ActionText::Content#to_s`: añadir allí un atributo cambia la respuesta de la API.
`test/controllers/cards/comments_controller_test.rb`, caso de actualización,
protege ese HTML; se conservó sin cambios y la integración respeta su contrato.
El observador decora bloques nuevos de forma idempotente; si Mermaid sustituye
un bloque por un diagrama, retira sólo los controles y conserva el diagrama.

## Verificación visual y límites

Fizzy real en modo OSS/desarrollo, SQLite y adjuntos de este checkout, puerto
local asignado por `bin/dev`: `http://127.0.0.1:3006`. Cuenta QA `2272`, creada
sólo en esa base; sin webhooks. Se capturó antes de cambiar la vista, y después
en escritorio 1280×900 y celular 390×844 con el mismo usuario y tema claro.
También hay capturas de Copiado, rechazo del portapapeles y tema oscuro.

`bin/agent-browser` verificó los tres bloques: cada llamada real a `writeText`
recibió exactamente el texto de su propio `pre` y terminó en Copiado. La lectura
del portapapeles en ese navegador de QA no tiene permiso; la igualdad de lectura
y escritura del portapapeles real se verificó en la prueba Selenium con permiso
explícito. El rechazo se provocó sólo en la página de QA, sin cambiar permisos
persistentes. Ningún comando mostrado se ejecutó.

No se verificaron Safari/iOS ni un celular físico. Touch se verificó en Chrome
con entrada CDP. No se desplegó ni publicó la instancia durable. La entrega usa
los gates de Dédalo y `bin/signoff`, aprobación por movimiento de tarjeta,
push del fork a `main` y `dedalo work landed`; el rollout de staff reconstruye
Fizzy con `bin/fizzy-local deploy` y comprueba su revisión. Guía canónica:
`docs/fizzy-custom-rollout.md` del workspace, no del fork.

## Resultado de las suites

- OSS/SQLite: `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=4
  CI_PROGRESS_BAR=false bin/rails test`: salida 0, 3.143 casos, 17.539
  aserciones, 5 omisiones de la suite existente.
- `bin/rubocop test/system/code_block_copy_test.rb`: un archivo sin infracciones.
  `node --check app/javascript/controllers/code_copy_controller.js`: salida 0.
- Suite completa `PARALLEL_WORKERS=1 bin/rails test:system`: 111 casos,
  786 aserciones, 0 fallos y 1 error al localizar un comentario en
  `CodeBlockStylingTest#test_inline_code_keeps_its_chip_background`.
  El mismo archivo aislado pasa en base y cambio: 2 casos, 4 aserciones.
- Repetición completa con `bin/rails test:system --seed 25845`, sin editar:
  111 casos, 780 aserciones, 1 fallo y 0 errores. Pasa el caso anterior y falla
  `CardStageNavigationTest#test_Done_from_the_mobile_header_offers_Continue_to_another_source_card`
  porque el título remoto no alcanza a refrescarse. Los seis casos nuevos pasan
  en las dos ejecuciones completas. No se declara verde la suite completa.
- La suite original de la exportación base, sin la candidata nueva, también
  presenta fallos variables: espera del proveedor en `AiSuggestionSystemTest`,
  inicio de sesión de otra prueba de esa clase y doble envío en
  `MagicLinkSubmissionTest`. No se modificó ninguna de esas pruebas.

Logs locales: `handy-2272-suite.log`, `handy-2272-system-initial.log`,
`handy-2272-system.log`, `handy-2272-base-system.log`,
`handy-2272-base-styling.log`, `handy-2272-styling-final.log`, bajo `.context/`.
La causa de esos fallos de la suite completa no se comprobó. La base también
falla, pero eso no demuestra por sí solo que todos tengan la misma causa.

El caso de navegación que falló también pasa aislado con el cambio:
`bin/rails test test/system/card_stage_navigation_test.rb -n /Done_from_the_mobile_header/`,
salida 0, 1 caso y 10 aserciones (`handy-2272-navigation-final.log`).
La candidata aplicada en RED y GREEN tiene SHA-256
`3759ce75a0c60d43f4bf194d49fd0a81298de5550756847f0d984e63bd2faf03`.
