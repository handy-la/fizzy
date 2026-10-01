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

RED: exit 1, 38 casos, 99 aserciones, 10 fallos, 0 errores. Los fallos fueron
entregas terminadas ante timeout, conexión rechazada, TLS y DNS; ausencia de
programación para 530 y espera creciente; adelanto de un comentario; reenvío
por job duplicado; y morosidad incrementada ante una entrega pendiente. El caso final adicional
comprueba que un fallo terminal no desactiva el receptor mientras otra entrega
espera un reintento; también falla en la base.
GREEN final: exit 0, 38 casos, 134 aserciones, 0 fallos, 0 errores.
Suite completa: mismo entorno, `PARALLEL_WORKERS=2`, `bin/rails test`;
exit 0, 1747 casos, 6668 aserciones, 0 fallos, 0 errores, 6 omisiones.
RuboCop: cinco archivos Ruby modificados, exit 0, sin infracciones.
La evidencia de trabajo está en `.context/handy-545-red-final.log` y
`.context/handy-545-green.log`; este resumen queda versionado para la revisión.

## Límites

La prueba de HTTP simula fallos con WebMock. No se detuvo el receptor real.
La comprobación de deduplicación del receptor fue de sólo lectura; no se cambió
su código ni se ejecutó su suite desde esta tarjeta. No se agregaron migraciones
ni APIs exclusivas para pruebas. No se retiraron pruebas ni seams.
