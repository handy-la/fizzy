# Salud del tick por columna — contrato v1

Fizzy recibe evidencia operacional de Dédalo. No consulta procesos, no programa
jobs y no cambia tarjetas. Conserva las esperas por tarjeta de Handy 2306.

## Configuración e identidad

`TICK_HEALTH_REGISTRY_FILE` apunta a un JSON local generado desde el registro
vigente de productos de Dédalo. Sin archivo no hay etapas configuradas ni
indicadores. No contiene credenciales. Forma:

```json
{"schema":1,"products":[{"id":"example","account_id":"1","board_id":"uuid-base36","producer_user_id":"uuid-base36","stages":[{"id":"deploying","column_id":"uuid-base36","description":"Comprobar despliegues"}]}]}
```

Cada tablero pertenece a un producto; cada etapa corresponde a una columna
real del tablero, por id. Las etapas humanas se omiten. No se deduce la etapa
por el nombre. Incluye deploying y publishing donde existan, sin una lista de
productos en Fizzy. La matriz completa y su adopción LIVE son de Dédalo 2574.
La instalación del archivo requiere los gates normales; esta tarjeta no
instala ni crea usuarios o tokens.

Autenticación existente de Fizzy: sesión o token Bearer. Un token de lectura
no escribe. Además, sólo `producer_user_id` de ese producto puede escribir,
con cuenta activa y acceso al tablero. Lectura y Cable exigen cuenta, usuario
activo y acceso actual al tablero. Un observador no puede configurar etapas.

## API

GET `/:account/boards/:board_id/tick_health` recupera el snapshot del tablero.
PUT `/:account/boards/:board_id/tick_health/:stage_id` acepta el documento de
`test/fixtures/files/tick_health/v1.json`, con `product_id` real.
JSON plano de hasta 8 KiB; todos los campos del fixture son obligatorios,
incluidos los null. Ninguna propiedad extra. Identificadores de hasta 100
caracteres, textos planos de hasta 200, sin controles, comandos ni secretos.
Fechas ISO8601 con zona explícita, calendario válido y precisión ≤6 decimales.

- schema: entero 1.
- expected_revision: entero ≥0; 0 si no existe la fila.
- run_sequence: entero positivo durable por etapa; no se reinicia al reiniciar.
- run_id: identificador estable de esa ejecución. La misma secuencia nunca
  puede identificar otro run.
- state: scheduled, running, waiting_ci, waiting_resource, deferred,
  lock_busy, noop, failed, no_signal, scheduler_missing o disabled.
- phase: explicación corta de lo que hace el tick; no es un log.
- phase_started_at: fecha o null (null sólo si no hay ejecución activa).
- reported_at: fecha de evidencia ≤ahora+60s; no ordena runs.
- valid_until: vigencia original, entre reported_at y reported_at+24h. Una
  fecha ya pasada es evidencia desactualizada y se guarda como tal.
- next_run_at: fecha real del scheduler o null. No es una ETA de entrega.
- expected_event: texto o null. Una espera CI/recurso/diferida/lock necesita
  evento o próxima corrida. scheduler_missing/disabled no llevan next_run_at.
- last_result: succeeded, noop, failed, cancelled o null.
- last_finished_at y last_reason: hora y causa saneada; ambas null si no hay
  resultado. El fallo anterior no sustituye al estado actual.
- duration_min_seconds / duration_max_seconds: rango de duración del tick,
  no ETA de entrega; enteros 0..86400 o ambos null. Requiere ≥5 muestras.
- duration_samples: entero 0..1000000. Sin muestra suficiente: sin estimación.

Tiempos de fase y resultado no posteriores a reported_at. Una actualización
del mismo run no puede retroceder reported_at. Enteros ≤2^53−1.

Respuestas PUT: 201 created, 200 updated/replayed. Reintento idéntico con
expected_revision anterior se reconoce antes de CAS; no duplica revisión ni
broadcast. Otro cuerpo con revisión antigua: 409 revision_mismatch. Run menor:
409 stale_run; misma secuencia y otro id: 409 run_conflict. Se valida y decide
bajo un lock de escritura del tablero (también SQLite). 422 invalid con
`details: [{attribute,code}]`, 413 body_too_large, 415 json_required,
400 invalid_json, 404 etapa/tablero no configurado o inaccesible, 403 productor
ajeno. Una lectura verifica el efecto. El servidor asigna la revisión.

Snapshot: schema, product_id, board_id, server_time y stages. Cada etapa trae
stage_id, column_id, description, revision, freshness y la evidencia, sin
expected_revision. Sin fila: revision 0, state no_signal. freshness current
sólo hasta valid_until, después stale. Ni cero ni stale implican éxito.

## Tiempo real y recuperación

TickHealthChannel recibe board_id, verifica acceso y abre un stream privado
por cuenta y tablero. La fila emite sólo una invalidación después del commit.
Cada entrega relee el snapshot y vuelve a comprobar acceso; no transmite el
payload de otro producto ni un estado guardado en memoria. `recover` al
confirmar cada suscripción cierra la carrera de conexión y permite reinicios.

El cliente conserva la revisión mayor de cada etapa, ignora duplicados y
mensajes viejos, y recupera snapshot por HTTP al cargar y volver online.
El zócalo reserva espacio en la base de la columna. Al plegarla, conserva dos
líneas verticales: estado con su icono monocromático y próximo tick o evento.
Cada estado tiene un icono distinto, incluido el estado local desactualizado.
La cuenta regresiva local avanza cada segundo, con cifras tabulares y espacio
fijo, sin tráfico de red. Al alcanzar el horario indica Pendiente; no crea un
run ni afirma que haya empezado. Una fuente vencida oculta ese reloj y muestra
No disponible. Sin señal, sin programador y deshabilitado tampoco anuncian una
fecha fiable. Las esperas por CI o recurso muestran el evento esperado cuando
existe. La fecha absoluta y la fase siguen disponibles en el detalle.
El detalle y la duración transcurrida se actualizan cada 15s. La vigencia del
resumen también se comprueba cada segundo.
Si falta socket no hay polling agresivo: vence la evidencia y deja de decir
En curso. Un error de broadcast no revierte la persistencia ni afecta al tick.
No se publican logs, comentarios, tokens o contenido comercial.

## Entrega y aceptación

Fixtures prueban el contrato, nunca adopción LIVE. La aceptación transversal
requiere productor real de Dédalo, API, Cable y DOM; después de las aprobaciones,
una corrida programada genuina. No instalar desde este worktree ni dar por
terminado ese circuito con un fixture.

## Geometría del tablero

El zócalo es hijo directo de la sección `.cards`. El contenedor
`.cards__transition-container` conserva el margen y la traslación de Fizzy.
Al plegar, la fila del zócalo deja un área propia para el contador y el título.
Al abrir, el espacio inferior se reserva en el contenedor de las tarjetas
para que el desplazamiento móvil llegue hasta la última. Mide las tarjetas o
la lista visible al verificar la alineación. El `turbo-frame` usa
`display: contents` y carece de caja propia.
