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

Antes de ampliar la prueba por el hallazgo de revisión: el contrato incluye
la actualización Turbo del borrador. La regresión es perder el mensaje o el
placeholder original cuando Turbo actualiza los atributos del título. El caso
existente de inserción se amplía para esperar `turbo:morph-element` del campo;
no requiere un seam productivo ni otro mock. La primera candidata sólo observaba
el campo antes de una actualización Turbo y no detectaba este riesgo. Se envía
el formulario real con `requestSubmit()`, sin publicar la tarjeta.

Base: `e6f95af120ca3b82fe60700b58494d3e8ec561db` de `fizzy-custom/origin/main`.
Candidata final de `test/system/ai_suggestion_test.rb`, SHA-256:
`517020c7f1a36a5db4764b6b32f29649561cf3f74251503f234e73ccad9e6b10`.
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

Resultado: exit 0; 4 casos, 36 aserciones, 0 fallos, errores ni omisiones.
Salida de trabajo: `.context/565-green-final.log`.

RED adicional contra la primera implementación
`2842471fa06ad4e25c9c7f3f11b760a5c0d29a9e`, antes de corregir su controlador:
el mismo entorno y `mise exec -- bin/rails test test/system/ai_suggestion_test.rb
-n /title_is_suggested/` terminaron con exit 1, un caso, ocho aserciones y un
fallo al buscar el mensaje después de recibir `turbo:morph-element`.
Salida de trabajo: `.context/565-morph-red.log`. La candidata y el código final
pasaron ese paso dentro del GREEN anterior.

La revisión describió el morph como parte del autoguardado. La comprobación
mostró que `helpers/form_helpers.js` pide JSON; el autoguardado actual no hace
ese morph. El fallo sí se reprodujo en la respuesta Turbo de `CardsController#update`.
El controlador final conserva el texto original y la espera en campos privados;
un observador del atributo `placeholder` restaura su presentación tras el morph.

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
33 casos, 184 aserciones, 0 fallos, 0 errores y 0 omisiones sobre el cambio final
que conserva el placeholder tras una actualización Turbo.

## Comprobación visual y límites

Capturas antes y después en el formulario real de un borrador local, mismo
usuario, tema y tamaño de 1.200 × 800. Una respuesta HTTP retenida permite
observar la espera sin depender de la velocidad del proveedor. El antes salió
del código base sin modificar; el después mostró el texto solicitado. Ambos
PNG están adjuntos a la tarjeta. Al liberar la respuesta, se insertó el título
editable y volvió `Name it…`.

No se verificó una llamada real a Fireworks, su latencia ni el despliegue.
Este cambio sólo presenta el estado existente de la sugerencia de título.
