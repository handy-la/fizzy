# Handy #627 — ficha de autoría y RED de las pruebas

Política: `test-audit` del poly-repo de Handy. Esta ficha cubre el botón del
extremo derecho de la barra flotante de la tarjeta, que ahora lleva al inicio
del último comentario. Sustituye el contrato «al final de la página» de
`docs/test-audits/handy-422.md`. No retira ninguna prueba ni seam.

## Evidencia RED y GREEN

- **Base:** `7162548c0c92de9e5a498bb17b3acce525c8cbbc` (`origin/main` de
  fizzy-custom al empezar la tarjeta; el botón baja al final de la página).
- **Método RED:** `git archive <base> | tar -x` en un directorio temporal
  aislado (scratchpad de la sesión, fuera de todo worktree), copia encima de
  `test/integration/card_dock_test.rb` y `test/system/card_dock_test.rb` de
  la tarjeta, y en ese directorio:
  `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 mise exec -- bin/rails test test/integration/card_dock_test.rb test/system/card_dock_test.rb`
  (variables de RVM/Bundler removidas).
- **RED 1 (exit 1):** 12 tests, 1 failure, 2 errors. La integración no
  encuentra `button[data-action="card-dock#scrollToLastComment"]`; las dos de
  sistema no encuentran el botón «Go to the last comment».
- **RED 2, de comportamiento (exit 1):** la misma copia, con el nombre viejo
  del botón (`click_on "Scroll to bottom"`) en la prueba de sistema:
  `Timeout::Error` en «the dock goes to the start of the last comment»; la
  ventana termina al final de la página y el comentario no queda arriba. El
  caso sin comentarios pasa en la base: conserva el comportamiento anterior.
- **RED 3, código resaltado (exit 1):** la primera versión del arreglo
  elegía `.comments .comment`, y Prism marca un comentario de código con la
  clase `comment`. Con la prueba de sistema actual (el último comentario
  termina en `<pre data-language="ruby">… # a code comment</pre>`) en una
  copia aislada con esa versión del controlador: `Timeout::Error`; la ventana
  queda en el código y no en el inicio del comentario. La prueba afirma
  primero que existe `pre .token.comment`, así que el RED no viene de un
  resaltado ausente.
- **GREEN:** el mismo comando en el checkout de la tarjeta: 12 tests, 0
  failures. Suite completa `bin/rails test`: 1762 tests, 0 failures (antes de la corrección
  del selector; esa corrección sólo toca JavaScript);
  `bin/rails test:system`: 39 tests, 0 failures (con la corrección).

## Las cuatro respuestas

### Acción del botón en el HTML (integration/card_dock_test, caso ampliado)

1. **Contrato:** el último elemento de la barra es un botón que llama a
   `card-dock#scrollToLastComment`. Dueño: `cards/container/_dock.html.erb`.
   Frontera: el HTML de `GET /cards/:id`.
2. **Regresión:** el botón vuelve a una acción que ya no existe o se pierde
   del extremo.
3. **Cobertura:** es el mismo caso de Handy #422, con la acción nueva. No se
   agrega un caso.
4. **Seam:** no requiere uno.

### Inicio del último comentario (system/card_dock_test, caso modificado)

1. **Contrato:** con la barra visible, el botón deja el inicio del último
   comentario visible a 16 px del borde superior de la ventana, aunque el
   comentario sea más alto que la ventana. Dueño:
   `card_dock_controller.js#scrollToLastComment`. Frontera: la posición del
   comentario en la ventana del navegador.
2. **Regresión:** volver a desplazar al final de la página (RED 2), elegir un
   comentario de código resaltado dentro del comentario (RED 3), el formulario
   de comentario nuevo, o un comentario de sistema oculto (su posición es 0 y
   la ventana subiría al principio).
3. **Cobertura:** la integración no ejecuta JavaScript. El caso de Handy #422
   afirmaba el final de la página, que ya no es el contrato; se modifica ese
   caso en vez de agregar otro.
4. **Seam:** no requiere uno.

### Tarjeta sin comentarios (system/card_dock_test, caso nuevo)

1. **Contrato:** sin comentarios visibles, el botón lleva al final de la
   página, como antes. Dueño: la rama de respaldo de `scrollToLastComment`.
   Frontera: `window.scrollY` contra la altura del documento.
2. **Regresión:** sin respaldo, el botón falla con un error de JavaScript o
   no mueve la ventana.
3. **Cobertura:** el caso anterior siempre tiene un comentario. Este
   conserva la afirmación de Handy #422 para el caso sin comentarios.
4. **Seam:** no requiere uno.

## Lo que no se verificó

- El desplazamiento en Safari o en la app nativa: la barra tiene
  `hide-on-native`, y las pruebas usan Chrome sin interfaz.
