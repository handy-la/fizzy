# Caché offline y cambio de sesión

Base: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.

## Autoría antes de editar las pruebas

- **Contrato:** Cache Storage nunca guarda PAT, enlaces de transferencia,
  exportaciones, notificaciones ni JSON autenticado. Sólo admite HTML de
  tableros y tarjetas con permiso explícito del servidor, separado por
  identidad, sesión y cuenta. Una transición de sesión espera el borrado antes de
  entregar la respuesta. Una petición anterior no puede repoblar la caché.
  Dueños: `ApplicationController`, `Authentication` y el service worker.
  Fronteras: respuestas HTTP y eventos fetch con Cache Storage real del navegador.
- **Regresión:** volver a la regla general permite guardar un PAT; omitir
  `no-store` permite retener su respuesta en otras cachés; quitar la partición
  permite leer otra cuenta; quitar la espera o el contador de generación
  permite entregar el logout o guardar una respuesta anterior antes del borrado.
- **Cobertura:** `my/access_tokens_controller_test.rb` prueba el PAT y su
  ventana, pero no las cabeceras. Las pruebas de sesiones prueban la cookie,
  pero no la orden de limpieza. `pwa_controller_test.rb` sólo comprueba CORS
  en el almacenamiento de adjuntos. Se amplían los casos HTTP y se sustituye
  esa prueba por el contrato de no guardar adjuntos privados: el worker deja
  de descargar o guardar adjuntos. Las pruebas de navegador observan el
  almacenamiento real, que las pruebas HTTP no ejecutan.
- **Seam:** ninguno exclusivo de pruebas. Las cabeceras de ámbito y borrado
  son un contrato HTTP que consume el service worker. Los tests acceden al
  worker y a Cache Storage mediante las API del navegador.

## Decisión de cobertura anterior

Las dos pruebas CORS de `PwaControllerTest` se conservan hasta decidir la
sustitución. El contrato anterior era usar CORS al descargar blobs; el contrato
nuevo es no almacenar blobs. La protección nueva debe pasar
antes de retirar esas comprobaciones. No se modifica el almacenamiento de
adjuntos en otros consumidores.

Casos adicionales del mismo contrato: dos cuentas de una identidad conservan
copias separadas; una petición JSON no puede leer la copia HTML; una respuesta
`no-store` revoca la copia anterior; una respuesta real detenida antes de
logout no repuebla la caché. La instrumentación CDP sólo retrasa `fetch` o
modifica su cabecera de almacenamiento; no devuelve el resultado esperado ni
cambia la lógica de Cache Storage. No agrega seams productivos.

Se amplían los contratos HTTP existentes de logout, passkey, transferencia,
cambio de correo, perfil, JSON y exportación con cabeceras `no-store` y borrado.
Los casos de navegador de HTML logout, transferencia y passkey comprueban
el borrado mediante sus rutas reales. Passkey usa una firma EC válida del
helper existente, con origen y RP ID del servidor local. No sustituye la
verificación WebAuthn ni agrega una API de prueba al producto.
Ambas rutas requieren una sesión anterior caducada: la prueba elimina esa
sesión en la base de datos tras guardar la página. No borra la caché. Eliminar
sólo la cookie permite que una respuesta anterior de Rails la vuelva a fijar
durante la carga de la página y hace inestable la precondición del caso.

Antes de agregar el caso de adjuntos/exportaciones/notificaciones: es la misma
frontera de Cache Storage. Usa un blob privado real y una exportación construida
por el modelo; exige respuestas HTTP 200 antes de buscar copias. La regresión
es la regla anterior para storage y la regla general. La prueba HTTP de exports
no ejecuta el worker y las pruebas CORS sólo buscan texto en su script.

## Retirada de las dos comprobaciones CORS

| Campo | Evidencia |
|---|---|
| Identidad y dueño | Los dos casos de `PwaControllerTest`; regla storage del worker |
| Fallo anterior | Omitir `mode: cors`, o ignorar `SERVICE_WORKER_CORS_ENABLED=false` |
| Historia | `7c9c12eb89f7a9556be6d7a01343d88232c940d8`, upstream habilitó esa opción |
| Consumidores | Búsqueda `rg SERVICE_WORKER_CORS_ENABLED`: worker, esos tests y Docker docs |
| Cobertura restante | El caso browser «exports notifications JSON and private blobs are never cached» usa un blob privado real, exige 200 y busca todas las entradas de Cache Storage |
| Riesgo | Los adjuntos dejan de estar disponibles offline. La red usa el Request original; ya no hay un fetch CORS especial que se pueda configurar |
| Validación antes de retirar | `bin/rails test test/system/offline_cache_test.rb`: 9 casos, 63 aserciones, verde |
| Decisión | Sustituir las comprobaciones textuales por el contrato real de no almacenar blobs; retirar la opción y actualizar Docker docs |

El helper que cambiaba ENV sólo servía a esos dos tests. No tiene consumidores
productivos ni otros consumidores de test; se retira con ellos.

El caso adicional de navegación completa comprueba que una ventana ya
confirmada conserva su página offline. Una navegación reemplaza el cliente:
el worker usa `replacesClientId` y entrega el ámbito al `resultingClientId`.
La prueba existente de fetch no observa ese ciclo de vida. No añade un seam.

Antes del caso de actualización: el contrato incluye borrar URLs y cuerpos
que guardó el worker anterior. Cache Storage y el registro IndexedDB son dos
almacenes distintos. Una conexión IndexedDB abierta puede bloquear
`deleteDatabase`; la limpieza debe vaciar el registro mediante una transacción.
La prueba siembra una capacidad ficticia en ambos almacenes, mantiene abierta
la conexión y activa el script real en un ámbito nuevo del mismo origen. Exige
que no queden copias. Un ámbito nuevo fuerza activate sin cambiar el producto;
cambiar sólo la URL no garantiza una actualización si los bytes son iguales.
La regresión es omitir la limpieza al activar o esperar un borrado bloqueado.
Las pruebas de logout no ejecutan activate; no hay un seam productivo nuevo.

## Reproducción y versión de las pruebas

El RED usa una exportación aislada de la base indicada, en
`.context/fizzy-red`, con la base SQLite preparada y sólo las pruebas
candidatas copiadas. No usa el source checkout ni otro worktree.
El GREEN usa `fizzy-custom/`. En ambos casos: Ruby 3.4.8 mediante mise,
Chromium 152.0.7977.82 y ChromeDriver del sistema, modo OSS y un worker.

SHA256 del lote de diez archivos de pruebas:
`b428ade1ba8527928a416d2de8c6fe365299b2f67efeec22d9ac27ac60017498`.
Se calcula con rutas relativas ordenadas, un byte NUL, contenido del archivo
y otro NUL para cada archivo. El comando enfocado es idéntico en RED y GREEN:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test \
  test/controllers/boards_controller_test.rb \
  test/controllers/my/access_tokens_controller_test.rb \
  test/controllers/pwa_controller_test.rb \
  test/controllers/sessions/passkeys_controller_test.rb \
  test/controllers/sessions/transfers_controller_test.rb \
  test/controllers/sessions_controller_test.rb \
  test/controllers/users/data_exports_controller_test.rb \
  test/controllers/users/email_addresses/confirmations_controller_test.rb \
  test/controllers/users_controller_test.rb \
  test/system/offline_cache_test.rb
```

RED: 117 casos, 626 aserciones, 24 fallos, cero errores; salida 1.
Los fallos observan PAT y transferencia guardados, logout JSON 204 con una
copia anterior, dos cuentas en `main`, `no-store` ignorado, respuestas tardías
que repueblan la caché, passkey y transferencia que dejan copias. Los cuatro
recursos sensibles responden 200 y quedan guardados. La activación conserva
la capacidad ficticia y un registro IndexedDB. Las cabeceras HTTP también
faltan. Las pruebas de navegación offline y logout HTML conservan cobertura
de funcionamiento y pasan sobre la base; no se presentan como RED nuevo.
GREEN: el mismo comando, 117 casos, 674 aserciones, cero fallos o errores;
salida 0. La prueba de actualización da `cached: false`, `count: 0`.
Las salidas completas locales están en `.context/red-final.log` y
`.context/green-final.log`; este resumen versionado conserva los resultados.

La suite completa `bin/rails test`, con el mismo entorno: 1864 casos,
7403 aserciones, cero fallos o errores, seis omitidos; salida 0.
`bin/rails test:system`: 54 casos, 398 aserciones, cero fallos, errores u
omitidos; salida 0. Los 14 archivos Ruby del lote pasan RuboCop.
`script/check_agents_docs`, `git diff --check` y la sintaxis JavaScript pasan.
No hay un job CI requerido para este repo en `dedalo.toml`.

La emulación offline se aplica al documento y al target del worker mediante
CDP `Network.emulateNetworkConditionsByRule`. Sólo desconectar el documento
permite que el worker siga usando la red y da una prueba falsa. Fuente:
[protocolo Network de Chromium](https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/pdl/domains/Network.pdl).
La navegación offline usa `page.visit`: el helper Rails `visit` también espera
conexiones Cable, que no pueden abrirse sin red. Capybara redefine el timeout
de scripts asíncronos: la activación usa `Capybara.using_wait_time(15)`.

La prueba existente de incorporación detectó que la espera de limpieza
permitía desactivar el campo del código antes de serializar el formulario.
Se reanuda mediante `requestSubmit`, con una guarda de reentrada, y el campo
se desactiva en `turbo:submit-start`, después de capturar sus datos.

## Límites de la comprobación

No se ejecutó Safari, Firefox, modo SaaS, MySQL ni un despliegue productivo.
La prueba de activación usa un ámbito nuevo; no reproduce una actualización
entre dos versiones descargadas del servidor. Comprueba el handler real y
ambos almacenes con una conexión abierta. El criterio de bytes pertenece al
[contrato de actualización de Service Workers](https://www.w3.org/TR/service-workers/).

La autorización offline vive en la memoria del worker. Después de su reinicio
se necesita una respuesta en red para confirmar la sesión y la cuenta; una
partición persistida por sí sola no concede acceso. Perfiles, adjuntos y URLs
firmadas requieren red. Push y el clic de notificación conservan sus handlers;
no se probó una entrega push real.
