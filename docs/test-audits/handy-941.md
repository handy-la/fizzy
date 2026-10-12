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

## Autoría al retomar: fecha autenticada por intento

- **Contrato:** según ADR-0053 del receptor, cada intento envía
  `X-Webhook-Timestamp` con su fecha actual y `X-Webhook-Attempt-Signature`
  como HMAC-SHA256 de `<fecha>.<cuerpo persistido>`. El cuerpo, el id del evento
  y `X-Webhook-Signature` permanecen iguales al reintentar. Ambas firmas se
  excluyen de `sanitized_request`, que alimenta la vista del historial.
- **Regresión:** conservar la fecha inicial impide reintentar después de cinco
  minutos; firmar un cuerpo renderizado de nuevo rompe la autenticación; omitir
  la firma de intento permite cambiar la fecha. Mostrar la nueva firma en el
  historial expone una solicitud autenticada.
- **Cobertura:** se amplían los casos `deliver`, `retry succeeds with the same
  signed bytes and event id`, `an interrupted request preserves bytes and its
  active lease is respected` y `sanitized_request strips signature header`.
  El segundo cubre reintentos de mensajes persistidos antes del despliegue;
  el tercero cubre recuperación tras una interrupción. Los casos TLS sólo
  observan el transporte y no prueban las firmas.
- **Seam:** entradas productivas `deliver` y `sanitized_request`. WebMock
  captura las cabeceras reales; el esperado usa directamente el contrato de
  HMAC de ADR-0053. Sin API nueva ni dependencia de Dédalo en la suite normal.
  La comprobación conjunta usará una exportación aislada de `origin/main`
  del receptor, sin cambiar su checkout ni enviar eventos reales.

Al actualizar la base, la serialización por cuenta impide la conexión TLS de
prueba mientras el fixture `in_progress` siga activo. Se completa ese fixture
en el setup, igual que en `DeliveryTest`: aislamiento de datos, sin cambiar
ninguna defensa de transporte. El contrato, regresión, cobertura y seam de
estos tres casos siguen siendo los del apartado «Transporte TLS real».

## Receptor y límites del contrato (antes de la dependencia)

El receptor pertenece a Dédalo, no a este repositorio. Antes de la dependencia,
`lib/dedalo/kanban/fizzy/webhook.rb` verificaba HMAC-SHA256 del cuerpo, pero no
verificaba antigüedad. La cabecera de fecha no participaba en la firma. La cola
`lib/dedalo/hooks/queue.rb` deduplica por id del evento mediante enlace atómico.
La lectura fue de sólo lectura; no se cambió el checkout de Dédalo.

Fizzy fijaba `X-Webhook-Timestamp` a `event.created_at` y conservaba cabeceras y
cuerpo durante 24 horas de reintentos. Exigir cinco minutos en el receptor sin
coordinar el contrato rechaza reintentos válidos. Comprobar sólo una cabecera
no firmada tampoco impide renovar la fecha de una solicitud capturada.
Dependencia registrada: [Dédalo 952](https://hermes.tailbaa835.ts.net:43008/1/cards/952).
La tarjeta esperó a que ese cambio llegara a `origin/main`. Su comprobación
tras reanudar está en el apartado final de este documento.

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
## Reanudación: contrato completo y validación final

Receptor leído desde `origin/main` de Dédalo:
`80abf3e4a258bd4bee48bf87709a570dd963fcbe`, ADR-0053. Ahora autentica
la fecha por intento, admite hasta 300 segundos de antigüedad y 60 segundos
hacia el futuro. Su primera firma de intento válida activa un candado contra
fechas sin firmar. La cola sigue deduplicando por id del evento. La edad se
comprueba al recibir, sin hacer vencer las entregas admitidas en cola.

El emisor renueva la fecha y su firma en cada intento sobre el cuerpo
persistido, también al reintentar un mensaje anterior al despliegue o recuperar
una interrupción. Conserva la firma del cuerpo. `sanitized_request` elimina
ambas firmas. Se renombró la migración a `20261012212000`: la base nueva
ya tenía otra migración `20261012180000`. El conflicto de versiones fue un
error de preparación y no se cuenta como RED.

Base productiva para el RED de la firma por intento:
`b5d868b12a97a631f79e0262943d98ea7454c01b`, después de rebase sobre
`6844763a8` de Fizzy. Sólo se aplicaron las pruebas candidatas y la corrección
del identificador de migración; el emisor todavía conservaba la fecha antigua.
Ruby 3.4.8, SQLite y sin SaaS. Comando exacto desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/models/webhook/delivery_test.rb
```

RED: salida 1, 40 casos, 141 aserciones, cuatro fallos y cero errores.
`deliver` envió la fecha del evento de un día atrás; el reintento y la
recuperación conservaron la fecha antigua tras seis minutos; el historial
mostró la firma de intento. Log: `.context/handy-941-attempt-red.log`.
GREEN del mismo comando: salida 0, 40 casos, 152 aserciones, cero fallos,
errores u omisiones. Log: `.context/handy-941-attempt-green.log`.

### Comprobación conjunta con el receptor

Se exportó el commit indicado de Dédalo mediante `git archive origin/main`
en `.context/handy-941-receiver`, sin editar su checkout. Una prueba temporal
`.context/handy-941-contract-test.rb` carga sus módulos reales `Webhook`,
`Hooks::Server` y `Hooks::Queue`, y una entrega real con fixtures de Fizzy.
WebMock captura el mensaje y lo entrega a `Server#handle`; la cola y su candado
viven en un directorio temporal aislado. No se accede a credenciales reales.

Comando: mismo entorno del RED, reemplazando el ejecutor por
`mise exec -- ruby -Itest ../.context/handy-941-contract-test.rb`, desde
`fizzy-custom/`. Salida 0, un caso, 26 aserciones. Log:
`.context/handy-941-contract.log`. Resultados observados:

- Primer intento: 202, una entrega en cola y candado de firma activado.
- Copia inmediata: 202 como duplicada; sólo una entrega en cola.
- Las firmas de una entrega admitida siguen válidas un día después.
- Tras aplicar el evento, el reintento seis minutos después conserva cuerpo,
  id y firma del cuerpo, renueva la firma de intento y recibe 202 como duplicado.
- El intento capturado fuera de la ventana recibe 401; cambiar su fecha sin
  volver a firmar o quitar la firma de intento también recibe 401.
- Una fecha firmada con 61 segundos hacia el futuro recibe 401.
- Un intento válido capturado y repetido 301 segundos después recibe 401.
- Al terminar: cero pendientes y un evento aplicado, sin doble aplicación.

### Checks finales

- Los cuatro archivos del lote, con el entorno anterior y un worker:
  53 casos, 226 aserciones, cero fallos, errores u omisiones, salida 0.
  Log: `.context/handy-941-resumed-focused.log`.
- Suite OSS completa, mismo entorno con `PARALLEL_WORKERS=4` y
  `mise exec -- bin/rails test`: 2.027 casos, 8.465 aserciones,
  cero fallos y errores, seis omisiones, salida 0.
  Log: `.context/handy-941-resumed-suite-green.log`.
- RuboCop en los siete archivos Ruby del cambio: salida 0, sin infracciones.
  Log: `.context/handy-941-rubocop.log`. `git diff --check`: salida 0.

No se ejecutaron MySQL, SaaS ni la suite de navegador. No se comprobó el
receptor remoto desplegado: el contrato se comprobó con el código publicado
y una cola aislada. No se cambió producción. Un rollback del emisor anterior
al cambio de firmas produce 401 una vez activo el candado del receptor, como
define ADR-0053. No quedan pasos manuales requeridos para activar el contrato.
No se retiraron pruebas ni seams. Sin cambio visual.
