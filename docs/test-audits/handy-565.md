# Espera visible de la sugerencia de título

## Autoría antes de editar las pruebas

- **Contrato:** el campo de título vacío muestra `Sugiriendo título...` mientras
  espera HTTP y mientras la solicitud está pendiente o en ejecución. Recupera
  su placeholder original al completar, fallar, cancelar o desconectar. El dueño
  es `ai_suggestion_controller.js`; la frontera es el campo real del navegador.
- **Regresión:** omitir el cambio del placeholder deja `Name it…` durante la
  espera; omitir la restauración deja un mensaje de generación sin trabajo activo.
- **Cobertura:** se amplía `title is suggested after typing stops and saved as
  an editable draft` en `test/system/ai_suggestion_test.rb`. Ese caso comprueba
  inserción y guardado, pero no la espera. Los casos nuevos comprueban la
  restauración y los estados pendientes recibidos por Cable. El caso existente
  de Cable observa sólo comentarios, cuyo placeholder tiene otra función.
- **Seam:** no se agrega una API productiva. Se usa el formulario real, el
  control HTTP existente del test y el canal real con estados persistidos en
  `Card::SuggestionRequest`. Se controla el tiempo del proveedor; no se prueba
  su texto ni su latencia. La prueba espera los mensajes `pending` y `running`
  del WebSocket real antes de observar el campo; no sustituye esos mensajes.

## Evidencia

Base: `e6f95af120ca3b82fe60700b58494d3e8ec561db` de `fizzy-custom/origin/main`.
Candidata final de `test/system/ai_suggestion_test.rb`, SHA-256:
`a80f421d8a74b51162c8f35315f443fc92bb70a201e3874660d1cf277cb40ccb`.
Entorno: Linux, Ruby 3.4.8 mediante mise, Chromium 152.0.7977.82.

RED: desde `fizzy-custom/`, exporté `origin/main` con `git archive` a
`/tmp/handy-565-red.yJWFqs` y copié sólo la candidata sobre su archivo de prueba.
El código productivo y la base SQLite de la exportación quedaron separados
del checkout de la tarjeta. Comando exacto:

```bash
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ruby -e 'Dir.chdir(ARGV.shift); load "bin/rails"' \
  /tmp/handy-565-red.yJWFqs test test/system/ai_suggestion_test.rb -n /title/
```

Resultado: exit 1; 4 casos, 12 aserciones, 3 fallos, 0 errores. Los tres casos
del placeholder fallaron al buscar `#card_title[placeholder="Sugiriendo título..."]`.
El campo seguía con `Name it…`. La prueba de eventos sintéticos, sin cambios,
pasó. Salida de trabajo: `.context/565-red-final.log` en el workspace.

GREEN: misma candidata sobre el cambio en `fizzy-custom/`:

```bash
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/system/ai_suggestion_test.rb -n /title/
```

Resultado: exit 0; 4 casos, 35 aserciones, 0 fallos, errores ni omisiones.
Salida de trabajo: `.context/565-green-final.log`.

La suite principal, con el mismo entorno y `mise exec -- bin/rails test`, pasó:
1.757 casos, 6.786 aserciones, 0 fallos, 0 errores y 6 omisiones existentes.
Rubocop del archivo de prueba pasó sin infracciones.

La primera ejecución secuencial de `bin/rails test:system` tuvo 33 casos,
181 aserciones, un fallo de `MarkdownPasteTest#test_markdown_paste_adds_block_spacing`
y ningún error. Una exportación de la base también falló al pegar Markdown
(2 casos, un error en `preserves line breaks`); una repetición aislada sobre el
cambio pasó ambos casos. Este problema intermitente queda fuera de la tarjeta.
Se registró como [Handy #568](https://hermes.tailbaa835.ts.net:43008/1/cards/568).
La repetición completa de `bin/rails test:system --seed 39952` pasó: exit 0,
33 casos, 183 aserciones, 0 fallos, 0 errores y 0 omisiones.

## Comprobación visual y límites

Capturas antes y después en el formulario real de un borrador local, mismo
usuario, tema y tamaño de 1.200 × 800. Una respuesta HTTP retenida permite
observar la espera sin depender de la velocidad del proveedor. El antes salió
del código base sin modificar; el después mostró el texto solicitado. Ambos
PNG están adjuntos a la tarjeta. Al liberar la respuesta, se insertó el título
editable y volvió `Name it…`.

No se verificó una llamada real a Fireworks, su latencia ni el despliegue.
Este cambio sólo presenta el estado existente de la sugerencia de título.
