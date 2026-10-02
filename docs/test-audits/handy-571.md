# Handy 571: sugerencia de comentario con un toque táctil

## Causa

En un celular, `pointerdown` sale con `touchstart`. El foco llega después de
levantar el dedo, con `mousedown`, `focusin` y `click`. `intent()` apaga
`#focusIntent` con `setTimeout(..., 0)` antes del foco, y `focus()` no pide
nada. Registro del toque en Chromium, en milisegundos de `performance.now()`:

```
pointerdown 957, touchstart 958, pointerup 1108, touchend 1108,
mousedown 1108, focusin 1109, click 1110
```

## Arreglo

`focus()` recuerda un foco confiable del editor sin intención previa
(`#tapFocus`). El `click` confiable siguiente, dentro del editor con el foco,
pide la sugerencia con las mismas guardas (`#stored`, `#request`, `#active`).
Cada foco autoriza como máximo un clic. Un foco programático solo no pide
nada; un clic sintético tampoco, porque `intent()` exige `isTrusted`. En la
computadora, `focus()` ya pidió con la intención de `pointerdown`, y el clic
no pide otra vez.

## Autoría antes de editar las pruebas

- **Contrato:** un toque táctil real en el comentario vacío pide una sola
  sugerencia y muestra «Preparando sugerencia…». Un foco por script seguido de
  un clic sintético no pide nada. El dueño es
  `app/javascript/controllers/ai_suggestion_controller.js` con la acción de
  `app/views/cards/comments/_new.html.erb`. La frontera es el editor real de
  la página y el `fetch` del controlador.
- **Regresión:** quitar `click->ai-suggestion#intent` o la rama `click` deja
  el toque sin solicitud (RED abajo). Aceptar un clic no confiable hace fallar
  el cero inicial (comprobado abajo).
- **Cobertura:** se agrega `a touch tap on the empty comment requests one
  suggestion` en `test/system/ai_suggestion_test.rb`. Los casos existentes
  usan el clic de ratón de Selenium (`find(...).click`) o Tab. En los dos,
  el foco llega dentro de la ventana de `#focusIntent`, y no detectan este
  fallo. `comment stays a placeholder until Enter accepts it without posting`
  sigue comprobando una sola solicitud con varios clics de ratón.
- **Seam:** no se agrega una API productiva. El toque llega por la acción
  táctil de WebDriver (`Interactions.pointer(:touch)`), con eventos
  confiables. Interceptar `fetch` sólo controla el proveedor, como en los
  demás casos del archivo.

## Evidencia

Repo `fizzy-custom`, base `18903586b4ac1cd35168f8b66500b28747d84052`
(`origin/main`). Ruby 3.4.8 de mise, Chromium 152.0.7977.82, SQLite.
Comando, en `fizzy-custom/`:

```
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test test/system/ai_suggestion_test.rb -n "/touch tap/"
```

- **RED:** con la prueba nueva y sin los cambios de `app/` (iguales a la
  base), salida 1: `Timeout::Error` en `wait_for_request`. Un diagnóstico
  temporal confirmó el foco en el editor (`contenteditable="true"`) y el orden
  de eventos de arriba. No es un error de carga.
- **GREEN:** con el arreglo, el mismo comando: salida 0, 1 caso,
  5 aserciones. El archivo completo, con el mismo comando sin `-n`: salida 0,
  12 casos, 89 aserciones. `bin/rails test:system` con el mismo entorno:
  salida 0, 34 casos, 191 aserciones.
- **Sensibilidad:** cambiar temporalmente la guarda a
  `if (!event.isTrusted && event.type !== "click") return` hace fallar el
  caso nuevo: `Expected: 0, Actual: 1`.

## No verificado

No se probó en un teléfono real ni en Firefox o Safari. La acción táctil de
WebDriver en Chromium reproduce el orden de eventos que describe la tarjeta.
