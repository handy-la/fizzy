# Handy 634: anuncio de espera para lectores de pantalla

## Autoría antes de editar las pruebas

- **Contrato:** mientras se genera la sugerencia de comentario, la región
  `role="status"` del formulario no está `hidden` y contiene
  «Preparando sugerencia…», pero no ocupa espacio visible (caja de 1 × 1 px como
  máximo). La espera visible sigue en el placeholder (Handy #631). Un error
  vuelve a mostrar la región a tamaño normal. Al terminar, omitir, escribir o
  desconectar el formulario, la región ya no contiene el texto de espera.
  Dueño: `ai_suggestion_controller.js`. Frontera: DOM del formulario real.
- **Regresión:** volver a `hidden` durante la espera (estado de `origin/main`)
  saca el texto del árbol de accesibilidad. Mostrar la región sin ocultarla a la
  vista agrega otra línea. Conservar la clase oculta tras un error esconde el
  error. No limpiar la región al desconectar deja un anuncio de espera falso.
- **Cobertura:** se amplían `comment stays a placeholder until Enter accepts it
  without posting` y `comment waiting placeholder is restored on failure
  cancellation and disconnection` de `test/system/ai_suggestion_test.rb`. Antes
  sólo comprobaban que la región no mostraba la espera; no si un lector la podía
  leer. El helper `assert_waiting_announced_off_screen` observa `hidden`, `role`,
  `textContent` y la caja, no el nombre de la clase CSS.
- **Seam:** no aplica. No se agrega una API productiva; se usa el control de
  `fetch` existente de la prueba.

## Evidencia

Base de `fizzy-custom`: `9380e19b9d1224094107aef1677c944d37a2c8a7`
(`origin/main`, incluye Handy #631). Ruby de mise, SQLite y Chromium. Se
aplicaron primero sólo las pruebas; el controlador seguía idéntico a la base.

Desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT -u RUBYLIB -u RBENV_VERSION -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test test/system/ai_suggestion_test.rb -n '/comment stays|comment waiting/'
```

- **RED:** salida 1; 2 casos, 11 aserciones, 2 fallos, sin errores. Los dos
  esperan `[false, "status", "Preparando sugerencia…"]` y reciben
  `[true, "status", "Preparando sugerencia…"]`: la región estaba `hidden`.
- **RED intermedio:** con sólo la clase oculta, el caso de desconexión falló
  porque `disconnect` ya no alcanza el target de Stimulus y la región conservaba
  la espera. El controlador guarda la región en `connect`, igual que `#input`.
- **GREEN:** archivo completo, mismo entorno: salida 0; 14 casos,
  153 aserciones, sin fallos ni errores.
- **Suite general:** `PARALLEL_WORKERS=4 … bin/rails test`: salida 0;
  1.762 casos, 6.834 aserciones, sin fallos ni errores, 6 omisiones.
- **Suite de interfaz:** `PARALLEL_WORKERS=1 … bin/rails test:system`: salida 0;
  41 casos, 284 aserciones, sin fallos, errores ni omisiones.

## No verificado

No se probó con un lector de pantalla físico (VoiceOver, TalkBack, NVDA) ni
con Safari o Firefox. La prueba comprueba el DOM que esos lectores leen, no el
anuncio hablado.
