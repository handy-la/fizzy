# Recursos de webhooks

## Admisión

- 5 webhooks por tablero y 20 por cuenta, activos o inactivos. Borrar libera
  el cupo de cantidad. Un exceso devuelve 422 sin webhook ni tracker.
- 10 peticiones de creación por minuto por cuenta, incluidos errores. Se
  guardan aparte de los webhooks: borrarlos no libera el límite de ritmo.
  Un exceso devuelve 429 antes de guardar el webhook.
- 100 entregas pendientes o en progreso por cuenta, compartidas por todos
  sus tableros y receptores. Un exceso no crea fila ni job. El evento sigue
  guardado; estas entregas descartadas no se reproducen después.

La creación, admisión y reserva de reintentos usan un UPDATE de cuenta antes
de contar, dentro de la transacción de escritura. Ese orden bloquea también
SQLite, donde un SELECT FOR UPDATE solo no protege la cuota.

## Turnos y aislamiento

El callback de evento admite hasta cinco receptores por tablero, ordenados por
id. No agrega un job por evento. Los tableros anteriores que exceden el cupo
conservan sus webhooks; reciben eventos sus primeros cinco receptores activos
que estén suscritos. Para usar otros, elimina o desactiva los anteriores.

`Webhook::Dispatch.schedule` toma el lock global mediante un UPDATE del
singleton y conserva un token con lease de cinco minutos. Todos los productores
comparten ese aviso. Sólo `Webhook::DispatchJob` envía HTTP; el job lleva un
token, sin una cuenta serializada que pueda desaparecer mientras espera.

El planificador rota IDs de cuenta después de cada turno y toma la primera
entrega lista de esa cuenta, por fecha e id. Revisa como máximo 100 candidatos
por cuenta por turno, incluso con un backlog antiguo. No envía sucesores
pendientes de una misma tarjeta; incluye eventos de sus comentarios. Los
bloqueados quedan en la base, sin un job que los despierte cada minuto.

El planificador serializa HTTP globalmente. El reclamo de la entrega bajo lock
de cuenta también impide HTTP simultáneo de dos receptores de una cuenta.
El lock no se mantiene durante HTTP. El throughput queda limitado a un envío
externo a la vez; un receptor lento puede consumir un turno de hasta el límite
HTTP existente, pero no todos los turnos ni los workers generales.

Los workers de `webhook_dispatch` y `webhooks` son exclusivos, con un hilo y un
proceso cada uno. Los workers de default, backend e incineration no consumen
esas colas. Los jobs de entrega anteriores sólo avisan al planificador; los
jobs anteriores de eventos conservan la admisión y el límite de fanout.

## Reintentos y recuperación

Hasta 8 intentos totales por entrega y 60 reintentos por hora por cuenta.
Los reintentos exitosos también consumen presupuesto. El contador por cuenta
se guarda en filas separadas, por lo que borrar un webhook no lo reinicia.
Un presupuesto agotado termina la entrega antes de otro HTTP y conserva la
última respuesta. `request.stopped_reason` identifica ese final. El plazo de
24 horas y los bytes firmados del primer intento siguen vigentes. La espera
crece de 1 a 30 minutos; el barrido puede agregar hasta un minuto de demora.

`Webhook::Dispatch.recover`, cada minuto, recupera entregas que quedaron en
progreso durante cinco minutos, elimina reservas de ritmo y reintento vencidas
y agrupa el siguiente aviso. También repone un token vencido si el job se perdió
antes o después de encolarlo. Una copia de un job en ejecución no libera su
lease, y un token anterior no reclama el token nuevo.

El despliegue aplica la migración y reinicia los workers mediante el flujo
normal. Durante el despliegue, los workers con código antiguo deben detenerse;
el aislamiento y los nuevos presupuestos rigen cuando los workers nuevos
cargan esta configuración.
