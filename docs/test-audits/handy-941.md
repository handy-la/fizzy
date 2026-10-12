# HTTPS obligatorio para webhooks: Handy 941

## Autoría antes de editar las pruebas

- **Contrato:** `Webhook` rechaza crear o actualizar una URL HTTP. `Delivery`
  bloquea un registro HTTP heredado antes de DNS y de abrir `Net::HTTP`, aun
  cuando ya conserve un mensaje para reintentar. La migración desactiva los
  destinos HTTP sin cambiar sus URLs, secretos ni entregas históricas.
  HTTPS conserva la IP pública fijada y el hostname lógico para TLS.
- **Regresión:** permitir HTTP en la validación admite destinos sin cifrado;
  confiar sólo en la validación permite enviar filas antiguas y reintentos;
  cambiar el hostname por la IP rompe SNI y la verificación del certificado.
- **Cobertura:** se amplía `WebhookTest#validates the url`, que hoy acepta
  HTTP, y el caso de IP fijada en `Webhook::DeliveryTest`. Los casos de DNS
  privado y NXDOMAIN no observan protocolos. Se agregan rechazos al actualizar,
  entregas HTTP heredadas nuevas y con mensaje persistido, y desactivación por
  migración de filas de distintas cuentas. No se retiran pruebas.
- **Seam:** entradas productivas `save`, `deliver` y `Migration#up`.
  Mocha observa la frontera DNS/HTTP; no implementa el rechazo esperado.
  No se agrega una API exclusiva para pruebas.

### Transporte TLS real

- **Contrato:** `deliver` debe conectar a la IP fijada, emitir SNI del hostname
  lógico y verificar tanto la confianza como el hostname del certificado.
- **Regresión:** sustituir el hostname por la IP o desactivar la verificación
  permitiría un servidor incorrecto. La prueba usa un servidor TLS local,
  un certificado generado para el caso y la biblioteca TLS real.
- **Cobertura:** el caso existente sólo sustituye `Net::HTTP` por un mock.
  Se agrega una frontera de transporte real con certificado correcto,
  certificado para otro hostname y certificado sin confianza.
- **Seam:** sin API nueva. Sólo se sustituye la resolución pública por loopback
  para alcanzar el servidor aislado y se instala su CA en el cliente real.
  WebMock se desactiva durante cada conexión y se restaura al terminar.
  Excepción RED: este contrato TLS ya existe y se conserva; estos casos deben
  pasar también antes del arreglo HTTPS. Se verificará su sensibilidad al
  desactivar temporalmente la verificación dentro de una exportación aislada.

## Receptor y límites del contrato

El receptor actual pertenece a Dédalo, no a este repositorio. Su módulo
`lib/dedalo/kanban/fizzy/webhook.rb` verifica HMAC-SHA256 del cuerpo, pero no
verifica antigüedad. La cabecera de fecha no participa en la firma. La cola
`lib/dedalo/hooks/queue.rb` deduplica por id del evento mediante enlace atómico.
La lectura fue de sólo lectura; no se cambió el checkout de Dédalo.

Fizzy fija `X-Webhook-Timestamp` a `event.created_at` y conserva cabeceras y
cuerpo durante 24 horas de reintentos. Exigir cinco minutos en el receptor sin
coordinar el contrato rechaza reintentos válidos. Comprobar sólo una cabecera
no firmada tampoco impide renovar la fecha de una solicitud capturada.
La ventana corta y su rechazo de replay quedan pendientes de resolver en el
producto dueño del receptor; esta tarjeta no debe declararse completa sin ello.

Dependencia registrada: [Dédalo 952](https://hermes.tailbaa835.ts.net:43008/1/cards/952).
Al retomarla, comprobar el contrato que llegue a `origin/main`, completar el
emisor y repetir la prueba de solicitud firmada fuera de la ventana. No se ha
verificado ni corregido todavía ese rechazo.

## Evidencia RED y GREEN del bloqueo HTTP

Base del repo: `1cde149e8e7b1f71fdcd25479ccb7ac3f5578f00`.
Las pruebas candidatas se ejecutaron en este checkout antes de modificar
el código productivo. Ruby 3.4.8 mediante mise, SQLite, sin SaaS.

Comando idéntico para RED y GREEN, desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/models/webhook_test.rb \
  test/models/webhook/delivery_test.rb
```

RED: salida 1; 49 casos, 176 aserciones, cinco fallos, cero errores.
Crear y actualizar HTTP devolvieron éxito. Las dos entregas antiguas llegaron
a resolver DNS. El quinto fallo fue el mensaje de validación anterior.
Log local: `.context/handy-941-red.log` en la raíz del workspace.

GREEN con ese mismo comando: salida 0; 49 casos, 202 aserciones,
cero fallos, errores u omisiones. Log local:
`.context/handy-941-original-command-green.log`.

GREEN con el caso de migración añadido:
salida 0; 50 casos, 210 aserciones, cero fallos, errores u omisiones.
Log local: `.context/handy-941-green.log`.

## Migración y sensibilidad de TLS

La migración es una entrada nueva, ausente en la base. Excepción RED explícita
para su caso: un `require` ausente sería un error de setup, no evidencia de
desactivación. Se prueba su comportamiento con filas HTTP de dos cuentas,
HTTPS activa, HTTP ya inactiva, conservación de URLs, secretos e historial,
ejecución repetida y rollback que no reactiva un destino inseguro.

Se exportó la base con `git archive HEAD` a `.context/handy-941-base`.
Se copiaron las pruebas TLS candidatas y las bases SQLite de prueba aisladas.
Las tres pruebas TLS pasan también con el código original: 14 aserciones,
salida 0. Esto confirma el contrato que la corrección conserva.

En esa exportación, se añadieron dos mutaciones controladas: desactivar
`verify_mode` y `verify_hostname` en el cliente TLS, y dejar vacía `up` en
una copia de la migración candidata. Tras preparar la base de la exportación,
se ejecutaron `tls_test.rb` y `https_migration_test.rb` con el mismo entorno.
Salida 1; cuatro casos, siete aserciones, tres fallos, cero errores.
Los certificados incorrectos dejaron de producir `failed_tls`; HTTP siguió
activo tras la migración. No es RED histórico; es evidencia de sensibilidad.
Log local: `.context/handy-941-sensitivity.log`.

## Validación y límites

- Suite OSS completa, mismo entorno y `PARALLEL_WORKERS=4`:
  `mise exec -- bin/rails test`; salida 0; 1.932 casos, 7.787 aserciones,
  cero fallos y errores, seis omisiones. Log: `.context/handy-941-suite.log`.
- TLS local real: tres casos, 14 aserciones, salida 0; certificado correcto,
  hostname incorrecto y CA sin confianza. Log: `.context/handy-941-tls.log`.
- Los cuatro archivos de pruebas del lote, con un worker: salida 0;
  53 casos, 224 aserciones, cero fallos, errores u omisiones.
  Log: `.context/handy-941-final-focused.log`.
- RuboCop sobre los siete archivos Ruby modificados: salida 0, sin infracciones.
- `git diff --check`: salida 0.

Se aplicó la migración a SQLite de prueba. MySQL no se ejecutó; su schema
sólo avanza la versión de esta migración de datos. No se cambió producción,
no se probaron receptores remotos ni se ejecutó SaaS o la suite de navegador.
El cambio no modifica marcado ni estilos. No se retiraron pruebas o seams.
Los gates finales y la entrega quedan pendientes del contrato del receptor.
