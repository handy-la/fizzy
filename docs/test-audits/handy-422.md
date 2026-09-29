# Handy #422 — ficha de autoría y RED de las pruebas

Política: `test-audit` del poly-repo de Handy. Esta ficha cubre los dos casos
nuevos de la barra flotante de la tarjeta. No retira ninguna prueba ni seam.

## Evidencia RED y GREEN

- **Base:** `031943281930d832544d882509e061d287ddf926` (`origin/main` de
  fizzy-custom al empezar la tarjeta; la barra sin los botones de los extremos).
- **Método RED:** `git archive <base> | tar -x` en un directorio temporal
  aislado (scratchpad de la sesión, fuera de todo worktree), copia encima de
  `test/integration/card_dock_test.rb` y `test/system/card_dock_test.rb` de
  la tarjeta, y en ese directorio:
  `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 mise exec -- bin/rails test test/integration/card_dock_test.rb test/system/card_dock_test.rb`
  (Ruby 3.4.8 de mise, SQLite, variables de RVM/Bundler removidas).
- **RED (exit 1):** 11 tests, 1 failure, 1 error.
  - integración: `Expected at least 1 element matching ".card-dock > .card-dock__edge--start:first-child a[href=…/boards/…]", found 0`.
  - sistema: `Capybara::ElementNotFound: Unable to find link or button "Scroll to bottom"` dentro de `.card-dock`.
- **GREEN:** el mismo comando en el checkout de la tarjeta: 11 tests, 0
  failures. Suite completa `bin/rails test`: 1732 tests, 0 failures;
  `bin/rails test:system`: 22 tests, 0 failures.

## Las cuatro respuestas

### Botones de los extremos en el HTML (card_dock_test, caso nuevo)

1. **Contrato:** la barra flotante de una tarjeta publicada, abierta o
   cerrada, tiene como primer elemento un enlace al tablero de la tarjeta y
   como último un botón que llama a `card-dock#scrollToBottom`. Dueño:
   `cards/container/_dock.html.erb`. Frontera: el HTML de `GET /cards/:id`.
2. **Regresión:** quitar uno de los dos botones, moverlo del extremo, o
   ligarlo sólo a tarjetas abiertas (como las etapas).
3. **Cobertura:** los casos existentes afirman las etapas y DONE, no los
   extremos. Se agrega un caso porque es un contrato nuevo.
4. **Seam:** no requiere uno.

### Comportamiento en el navegador (system/card_dock_test, caso nuevo)

1. **Contrato:** con la barra visible, «Scroll to bottom» lleva la ventana
   al final de la página, y «Back to <tablero>» abre el tablero. Dueño:
   `card_dock_controller.js#scrollToBottom` y el enlace de la barra.
   Frontera: la ventana del navegador y la URL actual.
2. **Regresión:** una acción de Stimulus mal escrita, un desplazamiento
   sobre un elemento que no es el que se desplaza, o CSS que deja el botón
   sin `pointer-events` (la barra ahora ocupa todo el ancho y sólo sus
   botones reciben el puntero).
3. **Cobertura:** la prueba de integración no ejecuta JavaScript ni CSS; las
   pruebas de sistema existentes sólo cubren la visibilidad y DONE.
4. **Seam:** no requiere uno.
