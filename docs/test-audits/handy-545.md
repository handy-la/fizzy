# Handy 545: entregas recuperables

## Autoría (antes de editar las pruebas)

- Contrato: Delivery y DeliveryJob deben recuperar errores de transporte y 5xx
  durante 24 horas, conservar los bytes y el id del evento, y no adelantar otra
  entrega de la misma tarjeta. DelinquencyTracker cuenta sólo fallos terminales.
- Regresión: completar un timeout/530 sin programar otro intento pierde el evento;
  regenerar el cuerpo cambia el mensaje; adelantar un cierre cambia su secuencia;
  contar cada intento puede desactivar el webhook durante mantenimiento.
- Cobertura: `delivery_test.rb` comprueba hoy que timeout y conexión rechazada
  terminan. Se amplían esos casos. `delinquency_tracker_test.rb` sólo observa
  éxitos y fallos terminales; se agrega cobertura del ciclo pendiente y agotado.
  Casos nuevos: 530/500, 4xx, recuperación, identidad, orden y agotamiento.
- Seam: entrada productiva `deliver` y ejecución de `DeliveryJob`; WebMock
  sustituye HTTP en la frontera de transporte. No se agrega API para tests.

## Receptor

Lectura del código instalado de Dédalo, sin modificarlo:
`lib/dedalo/hooks/delivery.rb`, `Delivery.id_for`, usa el `id` JSON del evento.
`lib/dedalo/hooks/queue.rb`, `Queue.enqueue`, rechaza ese id si está pendiente,
en ejecución, aplicado o muerto. Usa enlace atómico al crear el archivo pendiente.
La retención de aplicados es de siete días, mayor que nuestra ventana de 24 horas.
No se reenviaron eventos reales ni se repararon tarjetas antiguas.

## Evidencia RED y GREEN

Base del repo dueño: `b236ec4a1c210fbb32894ef8cdfb9e5eff8d2dd5`.
Se exportó con `git archive HEAD` a `.context/handy-545-base`, sin usar otro
worktree ni el checkout compartido. Se copiaron únicamente los dos archivos de
pruebas candidatos y las bases SQLite locales de prueba (en archivos separados).
Ruby 3.4.8 mediante mise; SQLite; sin SaaS.

Comando, en la exportación y luego en `fizzy-custom/`:

```bash
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test test/models/webhook/delivery_test.rb test/models/webhook/delinquency_tracker_test.rb
```

RED: exit 1, 40 casos, 104 aserciones, 12 fallos, 0 errores. Los fallos fueron
entregas terminadas ante timeout, conexión rechazada, TLS y DNS; ausencia de
programación para 530 y espera creciente; adelanto de un comentario; reenvío
por job duplicado; y morosidad incrementada ante una entrega pendiente. El caso final adicional
comprueba que un fallo terminal no desactiva el receptor mientras otra entrega
espera un reintento; también falla en la base.
GREEN final: exit 0, 41 casos, 154 aserciones, 0 fallos, 0 errores.
Suite completa: mismo entorno, `PARALLEL_WORKERS=2`, `bin/rails test`;
exit 0, 1750 casos, 6688 aserciones, 0 fallos, 0 errores, 6 omisiones.
RuboCop: seis archivos Ruby modificados, exit 0, sin infracciones.
La evidencia de trabajo está en `.context/handy-545-red-final.log` y
`.context/handy-545-green.log`; este resumen queda versionado para la revisión.

## Límites

La prueba de HTTP simula fallos con WebMock. No se detuvo el receptor real.
La comprobación de deduplicación del receptor fue de sólo lectura; no se cambió
su código ni se ejecutó su suite desde esta tarjeta. Se agregó una migración para ampliar `request`; no se agregaron APIs
exclusivas para pruebas. No se retiraron pruebas ni seams.

## Corrección de la primera revisión

Contrato adicional: una entrega cuyo worker murió debe volver a la cola y dejar
avanzar su tarjeta, conservando el mensaje del intento interrumpido. Regresión:
retornar ante cualquier `in_progress` deja una cadena bloqueada sin límite.
Cobertura anterior: sólo simulaba respuestas HTTP, sin muerte del worker.
Seam: `DeliveryJob.perform_now` sigue siendo la entrada real; el barrido recurrente
llama al método productivo de recuperación, bajo la cuenta de cada entrega.
Casos candidatos: una interrupción por `SystemExit` conserva bytes y respeta
el envío todavía activo; entrega en progreso con timestamp viejo, comentario posterior,
recuperación por job y avance de ambas entregas; no agrega API sólo para tests.

Los dos casos adicionales fallan en la misma exportación de la base (no por
API ausente): se envía el comentario fuera de orden y se reclama el envío activo.
Ambos pasan tras la recuperación. El barrido recurrente reutiliza esa recuperación
y se declara para producción y desarrollo en `config/recurring.yml`.

## Límite de almacenamiento encontrado por signoff

Contrato: los mensajes mayores de 64 KB que Fizzy ya podía enviar deben poder
persistirse y reintentarse. Regresión: guardar el cuerpo en `request` (TEXT de
65.535 bytes) falla antes del HTTP. La cobertura anterior usaba cuerpos pequeños.
La frontera sigue siendo `deliver` y HTTP real sustituido por WebMock; no agrega
seams. Se agrega un caso con una descripción grande, primer 530 y posterior 200,
que comprueba los bytes persistidos y recibidos sin truncarlos. Su RED se ejecuta
sobre el commit revisado anterior a la migración, no sobre la base original que
no persistía el cuerpo. La migración amplía la columna al mismo tipo largo que
usa ActionText. El rescue persiste sólo estado y timestamp, sin volver a guardar
los atributos que causaron el error.

RED del caso grande: base `cedf626aca75a6c2e8fcf318c526ac6947864685`,
exportada con `git archive` en `.context/handy-545-size-base`; mismo entorno
SQLite/Ruby 3.4.8. Comando:

```bash
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test test/models/webhook/delivery_test.rb -n /large_payloads/
```

Exit 1: `ActiveRecord::CheckViolation`, límite de `request` 65.535 bytes,
durante el guardado previo al HTTP; un caso, un error productivo, no un problema
de setup. Log de trabajo: `.context/handy-545-size-red.log`.
La migración se ejecutó en la base SQLite de prueba; el schema SQLite se generó
con Rails. El schema MySQL se actualizó con el equivalente LONGTEXT; no se
verificó contra un servidor MySQL real. El deploy normal aplica la migración.

GREEN del mismo comando `/large_payloads/`: exit 0, un caso, seis aserciones,
sin fallos ni errores (`.context/handy-545-size-green.log`).
