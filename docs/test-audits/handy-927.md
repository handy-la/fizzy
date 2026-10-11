# Handy 927: datos privados en caché offline

## Autoría antes de editar

- **Contrato:** el worker de Fizzy no guarda ni devuelve páginas ni adjuntos
  privados sin red. Sólo conserva recursos estáticos del mismo origen. Al
  actualizarse y al entrar en una pantalla, elimina las cachés antiguas `main`,
  `storage` y `assets`. El worker se puede actualizar sin sesión.
  Dueños: `pwa/service_worker.js.erb`, `initializers/offline.js` y
  `clear_offline_cache_controller.js`. Fronteras: HTTP y navegador Chromium con
  un worker real, Cache Storage real y red desconectada mediante CDP.
- **Regresión:** reinstalar las reglas de documentos o adjuntos devuelve los
  datos de la cuenta anterior tras revocar la sesión. Omitir la limpieza deja
  respuestas antiguas disponibles. Exigir sesión al servir el worker impide
  actualizarlo al expirar o revocar una sesión.
- **Cobertura:** `PwaControllerTest` sólo comprobaba dos variantes de CORS de
  la regla de adjuntos. Se sustituye ese contrato porque se elimina esa regla:
  las solicitudes de adjuntos conservan su modo original y usan sólo la red.
  Las pruebas de sesiones y de autorización de Active Storage consultan el
  servidor; no prueban Cache Storage ni respuestas offline del worker.
  `OfflineCacheTest` agrega esa frontera, sin duplicar la autorización HTTP.
- **Seam:** no se agrega una API para pruebas. Selenium usa CDP para desconectar
  la red y JavaScript para consultar las APIs públicas del navegador. Los
  archivos privados de prueba se adjuntan a una tarjeta real.

El caso de passkey usa el autenticador virtual público de Selenium/Chromium:
registra una passkey real para Kevin, cambia a David, pierde su sesión y vuelve
a Kevin con WebAuthn. Comprueba el borrado antes del POST, incluso cuando
`form.submit()` no emite un evento `submit`. Las pruebas HTTP de passkeys no
ejecutan ese componente ni consultan cachés. Se observan eventos reales de
formulario y Cache Storage; no se agrega un seam productivo.

## Decisión

Fizzy no ofrece almacenamiento offline cifrado y protegido por usuario.
Se elimina toda caché autenticada. Por eso no se crea un namespace por cuenta:
no hay datos autenticados que separar. El único namespace nuevo conserva
recursos estáticos públicos. La actualización mantiene las notificaciones push.

## Evidencia

Base de `fizzy-custom`: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.
Ruby 3.4.8 de mise, SQLite y Chromium 152.0.7977.82. Sin SaaS.

Prefijo de entorno usado en todos los comandos Rails desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT \
  -u RUBYLIB -u RBENV_VERSION -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/controllers/pwa_controller_test.rb test/system/offline_cache_test.rb
```

### RED histórico

Antes de editar producción se aplicaron los dos primeros casos del navegador.
`bin/rails test test/system/offline_cache_test.rb` dio salida 1: 2 casos,
10 aserciones, 2 fallos, sin errores. El caso de revocación recibió el HTML
privado de la tarjeta en vez de «network unavailable». El caso de login
conservó las cachés antiguas. Log: `.context/handy-927-red.log` de la raíz.

Se confirmó de nuevo sobre una exportación aislada de la base, creada con
`git archive` en `.context/handy-927-base`. Se copiaron allí las pruebas HTTP
y los cuatro primeros casos finales del navegador. No se usó otro worktree.
La copia RED del helper `wait_for_worker` registra el worker explícitamente
antes de esperar `ready`: así se evita el fallo previo de DOMContentLoaded y
se comprueba el almacenamiento real. La prueba entregada exige además que la
inicialización productiva registre el worker.

Con el mismo prefijo de entorno, la selección de Ruby se hizo antes de entrar
en la exportación:

```bash
mise exec -- bash -c 'cd ../.context/handy-927-base && bin/rails test test/controllers/pwa_controller_test.rb'
mise exec -- bash -c 'cd ../.context/handy-927-base && bin/rails test test/system/offline_cache_test.rb'
```

- HTTP: salida 1, 2 casos, 4 aserciones, 2 fallos, sin errores. El worker
  devuelve 302 al login cuando falta la sesión o fue revocada.
- Navegador: salida 1, 4 casos, 26 aserciones, 4 fallos, sin errores. La tarjeta
  sigue disponible sin red; login y logout dejan cachés privadas. En el POST
  de passkey siguen presentes `main`, `storage` y `assets`.
- Logs locales: `.context/handy-927-http-red.log` y
  `.context/handy-927-final-browser-red.log`. Los resultados quedan aquí para
  cuando se retire el worktree; los logs no se entregan al usuario.

### GREEN y composición del formulario

El comando enfocado de arriba dio salida 0: 7 casos, 41 aserciones, sin fallos,
errores ni omisiones. Incluye actualización del worker con la página abierta:
el nuevo worker se activa y elimina las cachés sembradas sin otra ejecución
de los módulos de página.

La primera suite de interfaz detectó una regresión intermedia en
`SmokeTest#test_joining_an_account`: `magic-link` desactivaba el campo después
de `requestSubmit`, mientras el borrado había detenido el envío. Al reanudar,
el código ya no se serializaba. Ahora se desactiva en `turbo:submit-start`,
después de que Turbo construye el cuerpo. El caso existente, sin modificar,
pasó con `bin/rails test test/system/smoke_test.rb -n /joining/`: salida 0,
1 caso, 4 aserciones. No se agrega una prueba que duplique ese contrato.

`bin/rubocop app/controllers/pwa_controller.rb test/controllers/pwa_controller_test.rb test/system/offline_cache_test.rb -f simple`
dio salida 0, sin infracciones.

La suite completa de interfaz, `bin/rails test:system` con el mismo entorno y
un worker, pasó: salida 0, 48 casos, 356 aserciones, sin fallos, errores ni
omisiones. La suite general `bin/rails test`, con `PARALLEL_WORKERS=4`, pasó:
salida 0, 1.865 casos, 7.369 aserciones, sin fallos ni errores, 6 omisiones.
Los logs se guardaron en `.context/handy-927-system-suite-final.log` y
`.context/handy-927-suite-final.log`. La sintaxis del worker y de los módulos nuevos
también pasa `node --check` (los módulos usan `--input-type=module`).

Después de la primera revisión se retiró la interceptación de GET privados:
el worker sólo responde por assets públicos. Así conserva la revalidación
HTTP y los 304 existentes. El comando enfocado completo se repitió sobre ese
ajuste: salida 0, 7 casos, 41 aserciones, sin fallos ni errores. Log:
`.context/handy-927-after-review.log`.

## Límites

- La revocación se simula borrando las sesiones en el servidor, antes de que
  el navegador observe una respuesta de login. La falta de cookie y la sesión
  revocada recorren el mismo estado sin autenticación. No se simula un reloj de
  expiración ni un revocador externo.
- No se probó Safari, Firefox ni un dispositivo nativo. La passkey pertenece
  a un autenticador virtual real, no a hardware físico. No se dispara una
  notificación push; se conserva su código.
- La actualización requiere red. Un navegador que todavía usa la versión
  antigua y permanece desconectado no puede recibir el arreglo.
- No se prueba la eliminación retrospectiva de la caché HTTP ni el historial
  de Turbo. El worker no intercepta las solicitudes privadas: conserva la
  política HTTP del servidor y no escribe Cache Storage. No se agrega
  almacenamiento autenticado, cifrado ni por cuenta.
