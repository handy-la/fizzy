# Handy 588: el título se sugiere al pegar la descripción

## Causa

El título se pide sólo cuando `intent()` ve un `beforeinput` confiable dentro
de la descripción. Al pegar, Lexical atiende el evento `paste` y llama a
`preventDefault()`. El navegador entonces no emite `beforeinput`
(`insertFromPaste`). El texto llega al editor y `lexxy:change` sale, pero
`#typed` sigue en falso y `change()` no programa la sugerencia. Las apps de
dictado pegan su texto, y por eso la persona tenía que escribir un espacio.

## Arreglo

La descripción del borrador escucha `paste->ai-suggestion#intent:capture`.
`intent()` trata un `paste` confiable dentro de la descripción igual que un
`beforeinput` de inserción. La captura corre antes del listener de Lexical en
el editable. La guarda `isTrusted`, el mínimo de 20 caracteres, el título
vacío y el debounce de 1,2 s no cambian.

## Autoría antes de editar las pruebas

- **Contrato:** pegar de verdad (Ctrl+V del portapapeles) una descripción
  suficiente en un borrador con título vacío pide una sugerencia de título y
  la pone en el campo. Un `paste` emitido por script, aunque Lexical inserte
  el texto, no pide nada. Dueño:
  `app/javascript/controllers/ai_suggestion_controller.js` con la acción de
  `app/views/cards/container/_content.html.erb`. Frontera: el editor real de
  la página y el `fetch` del controlador.
- **Regresión:** quitar la acción `paste` o la rama `paste` de `intent()` deja
  el pegado sin solicitud (RED abajo). Aceptar un `paste` no confiable hace
  fallar el caso de eventos sintéticos (sensibilidad abajo).
- **Cobertura:** se agrega `pasting a long description suggests the title` y
  se amplía `restored description and synthetic events do not request a
  title` con un `paste` por script. Los casos de título existentes escriben
  con `send_keys`, que emite `beforeinput`, y no detectan este fallo.
  `markdown_paste_test.rb` pega en comentarios con un evento sintético y no
  observa sugerencias.
- **Seam:** no se agrega una API productiva. El pegado real usa el portapapeles
  de Chromium (permiso por CDP `Browser.grantPermissions`) y Ctrl+V de
  WebDriver, que emite un `paste` confiable. Interceptar `fetch` sólo controla
  el proveedor, como en los demás casos del archivo.

## Evidencia

Repo `fizzy-custom`, base `ffbe3e0cae04746fad73ee4fdfad6b90100cb36a`
(`origin/main`). Ruby 3.4.8 de mise, Chromium 152.0.7977.82, SQLite.
Comando, en `fizzy-custom/`:

```
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test test/system/ai_suggestion_test.rb -n "/pasting/"
```

- **RED:** con la prueba nueva y sin los cambios de `app/` (iguales a la
  base), salida 1: `Timeout::Error` en `wait_for_request`. La aserción previa
  `assert_selector "lexxy-editor", text: "El recibo de la venta…"` pasó: el
  texto sí se pegó, y sólo faltó la solicitud.
- **GREEN:** con el arreglo, el mismo comando: salida 0, 1 caso,
  5 aserciones. `bin/rails test:system` con el mismo entorno: salida 0,
  35 casos, 197 aserciones.
- **Sensibilidad:** cambiar temporalmente la guarda a
  `if (!event.isTrusted && event.type !== "paste") return` hace fallar
  `restored description and synthetic events do not request a title`:
  `Expected: 0, Actual: 1`.

## No verificado

No se probó con una app de dictado real, ni en Firefox, Safari o un teléfono.
Una app que inserte el texto sin `paste` ni `beforeinput` (por ejemplo, con
eventos de accesibilidad) sigue sin pedir título.
