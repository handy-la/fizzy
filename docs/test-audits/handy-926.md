# Un envío durante la limpieza de caché

## Autoría antes de editar las pruebas

- **Contrato:** el formulario del código de acceso envía una sola petición,
  con el código completo, aunque el pegado y Enter lleguen mientras se borra
  Cache Storage. El formulario sigue validando campos vacíos. Dueño:
  `clear_offline_cache_controller.js`, usado por los formularios de sesión;
  frontera: eventos DOM y petición Turbo real en Chromium.
- **Regresión:** dos eventos submit pueden iniciar dos limpiezas y reanudar
  dos envíos; el segundo pierde el campo que desactivó el primero.
- **Cobertura:** `SmokeTest` comprueba incorporación con Enter y
  `OfflineCacheTest` comprueba el almacenamiento. Ninguno retiene
  `caches.delete` mientras ocurre otro envío. El nuevo caso observa ese orden
  y la carga HTTP; no repite comprobaciones del service worker.
- **Seam:** no se agrega una API productiva. La prueba retrasa la API real
  `caches.delete` con una promesa controlada y observa
  `turbo:before-fetch-request`. La petición de acceso continúa por su ruta real.

El segundo caso conserva la validación HTML y el reintento tras un fallo de
Cache Storage. Ese riesgo procede de introducir un bloqueo: sin liberación
en `finally`, un fallo impediría todos los intentos posteriores. Ninguna prueba
existente simula un rechazo de `caches.delete`. Se usa la misma API de navegador,
sin seam nuevo. Es cobertura del riesgo del arreglo; pasa sobre la base.

## Evidencia

Base del repo: `fb2af95ebcd8317391d7b3c7f715d22f97e81ffb`. Ruby 3.4.8 de
mise, SQLite, modo OSS y Chromium 152.0.7977.82 en Linux.
SHA256 de `test/system/magic_link_submission_test.rb`:
`776d2fb362f4ff6f58b3686cbdf13a442a7af5694863db426af86ba66b93f3ca`.

Se exportó esa base con `git archive` a
`../.context/handy-926-base` y se copió únicamente la prueba candidata.
Desde `fizzy-custom/`, el comando RED fue:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ruby -C ../.context/handy-926-base bin/rails test \
  test/system/magic_link_submission_test.rb
```

RED: salida 1; 2 casos, 11 aserciones, un fallo y cero errores.
El caso concurrente esperaba un borrado pendiente y encontró dos. El caso de
validación y reintento pasó. Salida local: `.context/handy-926-red.log`.
GREEN usa el mismo entorno y prueba sobre el repo corregido, sin `ruby -C`:
`mise exec -- bin/rails test test/system/magic_link_submission_test.rb`.
Salida 0; 2 casos, 14 aserciones, sin fallos, errores ni omisiones.
Salida local: `.context/handy-926-green.log`.

La comprobación adicional con `bin/agent-browser` sirvió la exportación por
Rails en el puerto del worktree. Se retrasó `caches.delete`, se disparó el
pegado de `ABCDEF` y se pulsó Enter. La base inició dos borrados y dos
solicitudes. Después se copió el controlador corregido a esa exportación y
se reinició el servidor: un borrado y una solicitud, con el código completo.
En ambos casos hubo cero solicitudes antes de liberar el borrado.
La instrumentación pausó `turbo:before-fetch-request`; confirma el envío doble,
pero no reproduce la pérdida posterior del código ni la cancelación HTTP.
La prueba de sistema GREEN sí reanuda la petición real con un código válido,
comprueba que se abandone el formulario y que el servidor consuma ese código.

Validación completa sobre el repo corregido, con el entorno anterior:

- `PARALLEL_WORKERS=4 mise exec -- bin/rails test`: salida 0; 2.046 casos,
  8.616 aserciones, cero fallos y errores, seis omisiones.
- `PARALLEL_WORKERS=1 mise exec -- bin/rails test:system`: salida 0; 63 casos,
  450 aserciones, cero fallos, errores y omisiones.
- RuboCop sobre el archivo nuevo: sin infracciones.
- `script/check_agents_docs`, `node --check` del controlador y
  `git diff --check`: salida 0.

No se retiró ninguna prueba ni seam. No se verificó Safari, Firefox, modo
SaaS, MySQL ni un despliegue productivo. El cambio no tiene efecto visual.

## Integración con main antes de publicar

Tras la aprobación se actualizó la base a
`79ec9b3bebf11becb32ce7b7faf08dd83f9cf148`. Main extrajo la limpieza a
`#clearCaches` y agregó un camino independiente de logout que retira push.
La resolución conserva esos métodos y aplica el bloqueo únicamente alrededor
de la llamada existente de `clearCache`.

Se repitió el RED con la misma prueba y entorno sobre una exportación aislada
de esa base en `.context/handy-926-rebase-base`; el comando anterior sustituye
`handy-926-base` por `handy-926-rebase-base`. Salida 1: 2 casos, 11 aserciones,
un fallo (dos borrados en lugar de uno), cero errores. El caso de reintento
sigue pasando. GREEN enfocado sobre la integración: salida 0; 2 casos,
14 aserciones, sin fallos ni errores. La prueba conserva el SHA256 anterior.

Los mismos comandos de suite sobre la integración dieron:

- Código: salida 0; 2.103 casos, 8.986 aserciones, cero fallos y errores,
  seis omisiones.
- Navegador: salida 0; 63 casos, 450 aserciones, sin fallos, errores ni omisiones.
- RuboCop del archivo de prueba, verificación de instrucciones, sintaxis
  JavaScript y `git diff --check`: salida 0.

Salidas locales: `.context/handy-926-red-rebase.log`,
`.context/handy-926-green-rebase.log`, `.context/handy-926-suite-rebase.log`
y `.context/handy-926-system-rebase.log`.
