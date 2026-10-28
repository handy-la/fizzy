# Conservar las líneas del comentario sugerido

## Autoría antes de editar la prueba

Base del repo: `a157a388f21d61bdf9502e1493c995c53290a5dd`.

- **Contrato:** aceptar con Enter conserva las líneas simples y vacías de la
  propuesta, también después de publicar. Dueño: `ai_suggestion_controller.js`,
  método `#accept`. Frontera: teclado y editor Lexxy real, envío del formulario
  y comentario renderizado por Action Text.
- **Regresión:** copiar texto con saltos literales dentro de un solo párrafo
  HTML fusiona sus líneas al importarlo en Lexxy.
- **Cobertura:** se amplía `comment stays a placeholder until Enter accepts it
  without posting`, que sólo usa una línea. El caso de Tab cubre el atajo y el
  de IME cubre publicación, pero ninguno exige saltos simples ni líneas vacías.
  Se conserva la comprobación de texto literal que parece HTML.
- **Seam:** ninguno nuevo. El helper existente intercepta sólo la respuesta de
  generación; aceptación, editor, publicación y renderizado son productivos.

## Evidencia

Prueba candidata: `test/system/ai_suggestion_test.rb`, SHA-256
`397827ecc1f0a90fdde626ff1901c5d58b7001ba831e824bfd01e9d0ae0367ad`.
Ruby 4.0.9 de mise, SQLite, Chromium sin interfaz. Desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u BUNDLE_GEMFILE \
  -u BUNDLE_PATH SAAS=false CI_PROGRESS_BAR=false PARALLEL_WORKERS=1 \
  mise exec -- bin/rails test test/system/ai_suggestion_test.rb \
  -n '/comment stays a placeholder/'
```

- **RED histórico:** antes de modificar el controlador de la base indicada,
  salida 1; 1 caso, 20 aserciones, 1 fallo. La comparación de `innerText`
  esperaba cuatro líneas (`resultado?\nSegunda línea.\n\n<script>…`) y recibió
  una sola (`resultado? Segunda línea. <script>…`). El fallo se produjo al
  aceptar con Enter, antes de publicar. Una primera ejecución con una llamada
  Selenium no disponible produjo un error de la prueba; no cuenta como RED.
- **GREEN:** mismo comando y prueba sobre el arreglo, salida 0; 1 caso,
  27 aserciones, sin fallos ni errores. Se verifica el placeholder completo,
  el editor después de Enter y el texto renderizado después de publicar.
- **Suite general:** mismo entorno con `PARALLEL_WORKERS=4`, comando
  `mise exec -- bin/rails test`: salida 0; 2.233 casos, 9.710 aserciones,
  0 fallos, 0 errores, 6 omisiones.
- **Suite de navegador:** mismo entorno con `PARALLEL_WORKERS=1`, comando
  `mise exec -- bin/rails test:system --seed 50614`: salida 0; 96 casos,
  628 aserciones, sin fallos, errores ni omisiones. La ejecución previa
  (`bin/rails test:system`, semilla aleatoria 50614) terminó con 96 casos,
  625 aserciones y un fallo en `PrivateOfflineCacheTest`, caso `passkey login
  clears the previous user's caches before submitting`, línea 128: no apareció
  la etiqueta de usuario después de entrar. La repetición aislada con
  `bin/rails test test/system/private_offline_cache_test.rb -n '/passkey login/'`
  pasó (salida 0; 1 caso, 9 aserciones), igual que la suite repetida con el
  mismo orden. No se cambió ese flujo ni se comprobó la causa del fallo inicial.
- **Estilo:** `mise exec -- bin/rubocop test/system/ai_suggestion_test.rb`,
  salida 0; un archivo inspeccionado, sin infracciones.

Se guardaron capturas de antes y después con el mismo usuario de fixtures,
tema y ventana (1.200 × 657). Para la captura posterior se añadió una llamada
temporal a `page.save_screenshot` después de comprobar el texto del editor;
se retiró antes de ejecutar la suite de sistema final. No cambia el escenario
ni la prueba entregada.

La respuesta de IA se controla con el helper existente. No se prueba el
proveedor externo: el defecto está en la conversión del texto recibido a HTML.
Las omisiones de la suite general no se consideran verificadas.
