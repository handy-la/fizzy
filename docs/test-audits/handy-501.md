# Handy 501: sugerencias de IA

## Autoría antes de editar pruebas

- Contrato: la petición autenticada solo lee una tarjeta accesible; un título usa la descripción actual del formulario; un comentario usa la descripción, todos los comentarios en orden y los eventos de la tarjeta. No crea comentarios ni modifica la tarjeta. La UI solo llena campos vacíos después de la pausa o al entrar el editor en pantalla.
- Regresión: omitir un comentario antiguo o reciente del contexto, consultar una tarjeta privada, escribir directamente el resultado o aplicar una respuesta tardía sobre texto del usuario viola estos contratos.
- Cobertura: `Cards::CommentsControllerTest` cubre publicaciones y permisos de comentarios, pero no existe una petición de sugerencias. `CardRefreshSystemTest` cubre edición y guardado, pero no la espera de IA ni su interacción con texto local.
- Seam: HTTP real de Rails y HTTP de Fireworks sustituido con WebMock; no se agrega un seam de producción para pruebas. El controlador Stimulus se verifica en el navegador real, con respuestas de red controladas.

## RED y GREEN

Base: `3333d381844ec659e48d198ab67b4cc6204585b1`. Ruby 3.4.8 de mise, SQLite, `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false`.

- Integración RED: en el checkout todavía sin implementación, `mise exec -- bin/rails test test/controllers/cards/suggestions_controller_test.rb`: exit 1, 5 casos, 5 fallos, sin errores; las peticiones devolvieron 404 porque faltaba el endpoint. Archivo final de pruebas idéntico salvo el cambio de sesión mediante `logout_and_sign_in_as` para garantizar que se prueba al usuario sin acceso.
- Integración GREEN: mismo comando con implementación: exit 0, 5 casos, 49 aserciones, sin fallos ni errores.
- Sistema RED: exportación aislada de la base con `git archive`, copia de la prueba final y `RAILS_ENV=test bin/rails db:prepare`; `bin/rails test test/system/ai_suggestion_test.rb` con el mismo Ruby y variables: exit 1, 4 casos, 3 errores de espera de la solicitud de sugerencia inexistente. El caso de borrador local ya pasa en la base. No son errores de dependencias ni de compilación.
- Sistema GREEN: mismo comando en el checkout de la tarjeta: exit 0, 4 casos, 20 aserciones, sin fallos ni errores.
- Suite de servidor: `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=2 CI_PROGRESS_BAR=false mise exec -- bin/rails test`: exit 0, 1737 casos, 6579 aserciones, 6 omisiones preexistentes.

No se retira ninguna prueba. Salidas locales: `.context/handy-501-{red,green,system-red,system-green,suite}.log` en la raíz del worktree. Esta ficha conserva los resultados para que la revisión no dependa de esos archivos temporales.

La prueba de sistema sustituye `window.fetch` solo para `/suggestion`, en el navegador de prueba. Permite resolver una respuesta después de escribir y borrar texto. No cambia el código de producción. La prueba de integración usa RubyLLM real y sustituye solo el HTTP de Fireworks.

Suite completa de navegador: `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test:system`, exit 0, 26 casos, 120 aserciones, sin fallos ni omisiones. RuboCop: los cuatro archivos Ruby nuevos sin infracciones. `node --check` y `git diff --check` pasan.

Prueba real con Fireworks sobre datos locales de desarrollo: título y respuesta generados mediante `Card::Suggestion`, sin cambios a la tarjeta ni publicaciones. Capturas antes/después adjuntas a la tarjeta con respuestas de red controladas. No se verificaron imágenes o archivos adjuntos como contexto multimodal; la función usa su texto disponible y el historial textual completo. Un contexto que supera 512 KiB o el límite del proveedor deja el campo disponible para escritura manual, sin usar solo una parte del historial.
