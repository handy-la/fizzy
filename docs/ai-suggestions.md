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
solicita. No afirma que la aprobación ni la ejecución ya ocurrieron. Para
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

## Entrega y aceptación

HTTP sólo crea o recupera la misma solicitud para el mismo usuario, tarjeta y
contexto. El job sigue en `ai_suggestions`, separado de las colas normales.
La transición a ejecución y el fin usan comparaciones de estado/token para
impedir que un job repetido genere de nuevo o sustituya otra revisión.

Cable usa usuario autenticado, token y revisión del cliente. El stream contiene
cuenta, usuario y solicitud. Las notificaciones no contienen la propuesta; el
canal comprueba acceso vigente y transmite el estado autorizado. Al confirmar
la suscripción o reconectar, el navegador recupera el estado, cubriendo también
un resultado anterior a la suscripción. Un único GET al vencimiento es respaldo
ante pérdida de conexión; no existe un bucle de polling del navegador.

SessionStorage conserva sólo token, vigencia y descarte, bajo una clave por
usuario y URL de cuenta. No guarda propuestas. Un fallo visible permite
reintentar. Un POST interrumpido puede repetirse; el servidor reutiliza el
trabajo pendiente. Una edición, aceptación o resultado obsoleto invalida la
propuesta en el cliente. Los streams de la página vuelven a comprobar contexto.

Sólo comentarios: se cambian los placeholders del contenedor y del editable
interior, con el texto exacto «Enter para aceptar». No cambia el valor ni
habilita publicación. Lexxy puede representar vacío como `<p><br></p>`; su
`isEmpty` evita que ese marcado se guarde como borrador. Enter simple se captura
antes del procesamiento de Lexical, copia texto mediante `textContent` y permite
editarlo. IME, repetición de tecla, Shift, Ctrl y Meta no lo aceptan. Ctrl/Meta
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
