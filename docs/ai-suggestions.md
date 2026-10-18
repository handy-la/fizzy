# Sugerencias de títulos y comentarios

La persona autorizó usar la versión más reciente de Kimi Fast en Handy 541.
El 2026-10-01 Fireworks publica Kimi K3 Fast con el ID
`accounts/fireworks/routers/kimi-k3-fast`. Fast se elige por ID de router;
`reasoning_effort: "none"` desactiva razonamiento por separado. No se usa
`service_tier` para Fast. Fuentes oficiales:
[Serverless Modes](https://docs.fireworks.ai/serverless/serverless-modes) y
[Chat Completions](https://docs.fireworks.ai/api-reference/post-chatcompletions).

## Petición efectiva

RubyLLM 2.0 hace POST a
`https://api.fireworks.ai/inference/v1/chat/completions` con:

```json
{
  "model": "accounts/fireworks/routers/kimi-k3-fast",
  "reasoning_effort": "none",
  "max_tokens": 2000,
  "messages": [
    { "role": "system", "content": "Instrucciones de Card::Suggestion" },
    { "role": "user", "content": "Contexto de la tarjeta" }
  ]
}
```

El router no está en el registro OpenAI de RubyLLM. Por eso se usa
`protocol: :chat_completions`, `assume_model_exists: true` y
`with_provider_options(reasoning_effort: "none")`: `with_thinking(false)`
requiere metadatos de registro para poder elegir el control de apagado.
Las pruebas inspeccionan el payload HTTP, no sólo el nombre del método.

Tres llamadas reales con cien comentarios sintéticos y una solicitud de
aprobación respondieron HTTP 200, `finish_reason=stop`, cero tokens de
razonamiento y modelo efectivo `accounts/fireworks/models/kimi-k3`. Tardaron
1,263 / 0,784 / 0,664 s. Generaron aprobaciones simples, sin afirmar ejecución.
Una llamada adicional por RubyLLM con el contexto de la tarjeta local sintética
terminó en 1,818 s. Estas muestras no estiman percentiles de producción.

El system prompt da prioridad a los últimos comentarios. Propone aprobar una
propuesta, autorizar comandos pendientes o aceptar un siguiente paso cuando se
solicita. Si los últimos comentarios dicen que quedan comandos o procesos por
correr a mano, la propuesta termina con una petición al agente: que los ejecute
él y no espere a una persona. No afirma que la aprobación ni la ejecución ya ocurrieron. Para
preguntas de hechos desconocidos pide aclaración. La propuesta es texto editable,
nunca una acción ejecutada por la IA.

## Plazos y estados

- Cola: diez minutos desde `requested_at`. Un job tardío pasa a `failed` con
  `queue_expired` y no llama al proveedor.
- Generación: HTTP de proveedor con timeout de 90 s, sin reintentos automáticos.
  La solicitud `running` tiene dos minutos de vigencia. El límite de concurrencia
  global del job es tres minutos y conserva un solo proveedor en curso.
- Resultado: quince minutos desde el fin, separado de la cola y generación.
  Después pasa a `failed/result_expired`. Un POST permite otro intento.

Los fallos observados antes de la tarjeta tardaban aproximadamente 20–35 s,
incluida cola; no prueban un timeout para todos los fallos. El timeout de 90 s
ofrece margen frente al límite anterior de 20 s; debe revisarse con las métricas
reales. Una prueba HTTP controlada tardó 25,1 s en generación y entregó por Cable.
No se afirma que toda petición real termine en 90 s de reloj: el timeout HTTP
no es una medición de duración total del job.

Un barrido cada minuto termina solicitudes pendientes o en ejecución vencidas,
incluso tras morir un worker. Leer estado o solicitar otro intento también hace
esa recuperación. Si el barrido no funciona y no hay lector, la fila no cambia
hasta la próxima recuperación; no se depende del barrido para reintentar.

`ai_suggestion_finished` registra sólo tipo, estado, categoría y milisegundos de
cola/generación. No registra prompt, texto ni mensajes de excepciones del
proveedor. La base conserva la propuesta durante su retención funcional.
Categorías: timeout, provider, empty, incomplete, context_too_large, interrupted,
queue_expired, result_expired, superseded y access_revoked.

## Admisión, presupuesto y turnos

El POST reserva capacidad antes de encolar, bajo un bloqueo global persistente
(`Card::SuggestionQueue`). Un UPDATE obtiene el bloqueo de escritura de SQLite
o de fila de MySQL antes de contar solicitudes. El bloqueo abarca la reserva,
el cambio de estado y la creación de la solicitud; no abarca la llamada externa.

Los límites incluyen `pending` y `running` vigentes: una solicitud por usuario
(membresía), dos por cuenta y cuatro globales. Se permite recuperar la misma
solicitud y contexto sin ocupar otro cupo ni crear otro job. Cambiar el contexto
mientras sigue activa devuelve 429; no reemplaza el token ni reinicia el plazo.
Un exceso de capacidad devuelve 429 antes de crear trabajo, con
`Retry-After: 90` como intervalo de reintento, no como garantía de disponibilidad.
Un presupuesto agotado devuelve 429 con `Retry-After` igual a los segundos que
faltan para que venza la reserva más antigua de ese presupuesto (cuenta o global).
El navegador muestra «Cupo de sugerencias agotado; intenta en N minutos.» con
el botón de reintento; sin `Retry-After` válido dice «intenta más tarde».

Cada nueva admisión reserva una llamada: diez por cuenta y sesenta globales en
una ventana móvil de una hora. Con `MULTI_TENANT` apagado hay una sola cuenta:
su presupuesto es el global, porque diez por hora alcanzaban para todas las
personas juntas (Handy #999); el global pasó de treinta a sesenta en Handy #1157.
`AI_SUGGESTION_ACCOUNT_BUDGET` y
`AI_SUGGESTION_GLOBAL_BUDGET` reemplazan cada valor con un entero positivo;
un valor vacío o inválido usa el predeterminado. El global sigue como tope. `Card::SuggestionAdmission` conserva esa reserva
independiente de la fila reutilizable de la solicitud. Un timeout, una
cancelación o una solicitud que vence no devuelve presupuesto. Recuperar un
resultado ya terminado no vuelve a gastar. Las reservas viejas se borran bajo
el mismo bloqueo, al admitir otra petición. No se guarda texto ni token en ellas.
Es un presupuesto de llamadas admitidas, no una medición del costo en moneda.

Los jobs nuevos son avisos globales sin argumentos ni cuenta serializada.
`Card::SuggestionJob` conserva compatibilidad con los argumentos antiguos.
Al ejecutarse, el aviso escoge la siguiente cuenta después del cursor persistido
por ID y vuelve al principio al acabar la ronda; dentro de la cuenta toma la
solicitud más antigua por fecha e ID. La reclamación vuelve a comprobar el turno
y la ausencia de otra generación vigente bajo el bloqueo global. El proveedor
se llama fuera del bloqueo y con el contexto de la cuenta seleccionada.

El límite de concurrencia de Solid Queue sigue en uno. La vigencia `running`
aporta además una reserva entre procesos. El barrido existente recupera trabajo
pendiente sin una generación vigente: encola un aviso después de vencer un
worker perdido. No reintenta la llamada perdida ni devuelve su presupuesto.
Con cuatro solicitudes y llamadas de 90 s, el lote tarda seis minutos y el último
comienza a los 270 s, dentro de los diez minutos de cola. Esta cuenta no incluye
un worker detenido ni solicitudes antiguas del despliegue; esas filas mantienen
su vencimiento original. No se afirma un plazo absoluto del proveedor real.

La migración agrega las tablas de bloqueo y reservas y un índice por usuario,
estado y vencimiento. Debe aplicarse antes de iniciar el código nuevo.
Evidencia de admisión concurrente, presupuestos, turnos y recuperación:
`docs/test-audits/handy-934.md`.

## Entrega y aceptación

HTTP crea una solicitud dentro de los cupos o recupera la misma solicitud para
el mismo usuario, tarjeta y contexto. El job sigue en `ai_suggestions`, separado de las colas normales.
La transición a ejecución y el fin usan comparaciones de estado/token para
impedir que un job repetido genere de nuevo o sustituya otra revisión.

Cable usa usuario autenticado, token y revisión del cliente. El stream contiene
cuenta, usuario y solicitud. Las notificaciones no contienen la propuesta; el
canal comprueba acceso vigente y transmite el estado autorizado. Al confirmar
la suscripción o reconectar, el navegador recupera el estado, cubriendo también
un resultado anterior a la suscripción. Un único GET al vencimiento es respaldo
ante pérdida de conexión; no existe un bucle de polling del navegador.

Cable rechaza cuentas canceladas. Las sugerencias exigen una cuenta activa al
suscribirse, antes de llamar al proveedor y antes de transmitir el estado.
Los controles recargan la cuenta:
una asociación ya cargada puede conservar el estado previo a una cancelación.
El canal vuelve a comprobar acceso después de leer el estado, antes de enviar
texto. Una cuenta en importación tampoco puede usar IA; su conexión general
de Cable se conserva para mostrar el progreso en `account/imports/show`.

`Account::Cancellation` revoca las solicitudes `pending`, `running` y
`completed` dentro de la transacción de cancelación. Guarda `access_revoked`
y borra descripción y propuesta. Un job tardío no puede sustituir ese estado;
reactivar la cuenta tampoco recupera las propuestas revocadas. El cierre de
Cable ocurre en `after_create_commit`, por los usuarios de esa cuenta, sin
reconexión automática. No se cierran todas las conexiones de la identidad:
puede tener membresías en otras cuentas activas.

Una llamada HTTP que ya comenzó antes de cancelar no se puede retirar del
proveedor. El worker comprueba acceso al volver y descarta su resultado. No
mantiene un bloqueo de cuenta durante la llamada HTTP. Las pruebas usan HTTP
controlado; no afirman cancelar una petición externa en curso.

SessionStorage conserva sólo token, vigencia y descarte, bajo una clave por
usuario y URL de cuenta. No guarda propuestas. Un fallo visible permite
reintentar. Un POST interrumpido puede repetirse; el servidor reutiliza el
trabajo pendiente. Una edición, aceptación o resultado obsoleto invalida la
propuesta en el cliente. Los streams de la página vuelven a comprobar contexto.

Sólo comentarios: se cambian los placeholders del contenedor y del editable
interior. Durante la espera muestran «Preparando sugerencia…», sin una línea
de estado visible aparte; la región `role="status"` conserva el mismo texto
oculto a la vista para que lo anuncie un lector de pantalla. Esa región nunca
usa `hidden`: vacía o en espera queda fuera de pantalla, porque una región viva
expuesta ya con texto no se anuncia de forma fiable. Al llegar la propuesta muestran sólo su
texto, sin instrucción de tecla (Handy #1218). Los errores y el botón de reintento siguen debajo del
campo. No cambia el valor ni
habilita publicación. Lexxy puede representar vacío como `<p><br></p>`; su
`isEmpty` evita que ese marcado se guarde como borrador. Enter o Tab simple se
captura antes del procesamiento de Lexical, copia texto mediante `textContent` y
permite editarlo; Tab no mueve el foco al aceptar. IME, repetición de tecla,
Shift, Ctrl y Meta no lo aceptan: Shift+Tab sigue navegando. Ctrl/Meta
conservan el atajo existente de publicación. Turbo puede quitar la asociación
Stimulus antes de ejecutar `disconnect`: se conserva la referencia del editor
para restaurar ambos placeholders, y al reconectar se recupera el resultado.

El comentario se pide al enfocar el editor con puntero o Tab. En un celular el
foco llega al levantar el dedo, después de que la intención de `pointerdown`
expiró: ese foco queda pendiente y el `click` confiable del mismo toque, dentro
del editor enfocado, pide la sugerencia. Un foco autoriza un solo clic.
Evidencia: `docs/test-audits/handy-571.md`.

El título se pide 1,2 s después de una edición real de la descripción: un
`beforeinput` confiable o un `paste` confiable. Lexical cancela el pegado
antes de que el navegador emita `beforeinput`, y las apps de dictado pegan su
texto: por eso el `paste` cuenta como edición. Un pegado por script no cuenta.
Evidencia: `docs/test-audits/handy-588.md`.

El título mantiene su inserción editable y su guardado actuales. El límite de
255 caracteres sigue vigente. Los comentarios mayores de 8.000 caracteres se
rechazan como incompletos, sin recortarlos.
