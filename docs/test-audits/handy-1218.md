# Aceptar la sugerencia de comentario con Tab, sin instrucción visible

## Cambio

La propuesta de comentario se mostraba en el placeholder con una segunda línea
«Enter para aceptar», y sólo Enter la aceptaba. Ahora el placeholder muestra
sólo el texto propuesto, y Enter o Tab simple la aceptan. Tab no mueve el foco
al aceptar: el handler de captura llama `preventDefault`. Sin propuesta, Tab
navega igual que antes. Shift+Tab, Ctrl, Meta, Alt, IME y repetición de tecla
no aceptan.

## Autoría antes de editar pruebas

Base: `97396918c70a99f3108dc28ca3de5c7b127f1cf2`.

- **Contrato:** con una propuesta visible y el campo vacío, el placeholder del
  contenedor y del editable es exactamente el texto propuesto; Tab copia la
  propuesta al campo, deja el foco en el editable y no publica. Dueño:
  `ai_suggestion_controller.js` (`#accept`, `#renderPlaceholder`). Frontera:
  DOM y teclado real de Chromium.
- **Regresión:** volver a agregar una instrucción de tecla al placeholder;
  limitar `#accept` a Enter; dejar que Tab siga al navegador y mueva el foco.
- **Cobertura:** `comment stays a placeholder until Enter accepts it without
  posting` y `IME and Shift do not accept…` cubren Enter, IME y Shift. Ninguna
  prueba pulsaba Tab con una propuesta visible, y las aserciones existentes
  buscaban «Enter para aceptar» como señal de propuesta visible. Se agrega el
  caso `Tab accepts the comment suggestion and the placeholder shows no key
  hint`, y las cinco aserciones existentes buscan ahora el texto propuesto.
- **Seam:** ninguno. La prueba usa el fetch interceptado que ya usa el archivo.

## Evidencia RED y GREEN

Desde `fizzy-custom/`, con Ruby de mise y Chromium:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u BUNDLE_GEMFILE \
  -u BUNDLE_PATH SAAS=false CI_PROGRESS_BAR=false mise exec -- \
  bin/rails test test/system/ai_suggestion_test.rb -n "/Tab accepts/"
```

- **RED 1, base sin cambios:** falla en la línea del placeholder:
  `expected to find css ".comment--new lexxy-editor[placeholder=\"Sí, adelante.\"]"
  but there were no matches` (el placeholder tenía «Enter para aceptar»).
- **RED 2, sólo el placeholder corregido:** falla después de Tab:
  `expected to find visible css ".comment--new lexxy-editor" with text "Sí,
  adelante." … Also found ""` (Tab no aceptaba).
- **GREEN, con ambos cambios:** `bin/rails test test/system/ai_suggestion_test.rb`
  completo: 16 runs, 185 assertions, 0 failures.

La prueba `keyboard focus can recover an interrupted POST` sigue verde: un Tab
que llega al editable desde la barra no acepta, porque su destino es el botón.
