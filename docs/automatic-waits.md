# Espera automática en tarjetas

Contrato entre Fizzy y un productor externo (Dédalo) para declarar que una
tarjeta espera al sistema: una CI en cola o en ejecución, o un monitor
registrado. Fizzy guarda y muestra lo que el productor declara. **No infiere
una espera** de comentarios, antigüedad, columna ni agentes inactivos, y
mostrarla no cambia la tarjeta: ni su columna, ni su cierre, ni su actividad
(`last_active_at`), ni una aprobación o un pendiente humano.

Esta pieza entrega almacenamiento, API y presentación. Los productores y la
publicación son de Dédalo, y la integración real Dédalo → API → tarjeta la
verifica Dédalo después (Handy #2306, origen Dédalo #2302).

Código: `Card::AutomaticWait` (fila), `Card::AutomaticWait::Declaration`
(único escritor), `Card::AutomaticWait::Summary` (publicación agregada),
`Card::AutomaticWait::Fence` (protección por tarjeta),
`Cards::AutomaticWaitsController`, la vista
`cards/display/preview/_automatic_waits` y `automatic_wait_controller.js`.
Pruebas y ficha: [`docs/test-audits/handy-2306.md`](test-audits/handy-2306.md).

## Autenticación y autorización

La existente: sesión o token `Authorization: Bearer …` de Fizzy. Un token de
lectura puede leer; escribir con él contesta 401 `insufficient_scope` (403 si
es de una app OAuth), como en todo Fizzy. Cada operación resuelve la tarjeta
con `Current.user.accessible_cards` dentro de la cuenta de la URL: comprueba
cuenta, acceso al tablero, pertenencia de la tarjeta y borradores de otro
usuario. Una tarjeta inaccesible contesta 404; una cuenta sin usuario para la
identidad contesta 403. Esta pieza no agrega permisos ni secretos.

## Rutas

Todas bajo la cuenta: `/:account_slug/cards/:card_number/automatic_waits`.
Son JSON siempre (la ruta fija el formato). `:key` cumple
`^[a-z0-9][a-z0-9._:-]{0,63}$`, por ejemplo `ci:rails-test` o `monitor:fleet`.

| Método | Ruta | Uso |
|---|---|---|
| `GET` | `…/automatic_waits` | Lee todas las filas de la tarjeta y la publicación agregada. Sirve para verificar cada escritura y para retomar después de un reinicio. |
| `PUT` | `…/automatic_waits/:key` | Declara o actualiza una espera. |
| `DELETE` | `…/automatic_waits/:key` | Limpia una espera (deja una lápida). |

`PUT` y `DELETE` exigen `Content-Type: application/json`, un objeto JSON plano
de 8 KiB como máximo y **ninguna propiedad fuera de la lista**.

### Cuerpo de `PUT`

| Propiedad | Tipo | Obligatoria | Regla |
|---|---|---|---|
| `epoch` | entero ≥ 0 | sí | Época actual de la tarjeta (de `GET`). |
| `expected_revision` | entero ≥ 0 | sí | Revisión que leyó el productor; `0` para una clave nueva. |
| `owner` | identificador | sí | Owner durable, p. ej. `dedalo:handy`. |
| `replaces_owner` | identificador | no | Sólo para un relevo de owner: el owner actual. |
| `run_id` | identificador | sí | Ejecución, p. ej. `ci-4182`. |
| `run_sequence` | entero ≥ 1 | sí | Orden creciente de las ejecuciones de esa clave. |
| `producer` | `ci` \| `monitor` | sí | Productor autorizado. |
| `state` | `queued` \| `running` (ci); `monitoring` (monitor) | sí | Otro valor es 422. |
| `reason` | texto ≤ 200 | sí | Motivo visible en la tarjeta. |
| `expected_event` | texto ≤ 200 | sí | Evento que se espera; se muestra si no hay revisión programada. |
| `next_check_at` | fecha | no | Próxima revisión. Sin ella, la espera es sólo por evento. |
| `valid_until` | fecha | sí | Vigencia de la declaración. |
| `human_condition` | `required` \| `pending` \| `unknown` \| `not_required` | sí | Condición humana declarada. |

Un identificador cumple `^[a-z0-9][a-z0-9._:-]{0,99}$`. Una fecha es
`AAAA-MM-DDTHH:MM:SS[.ffffff]` con zona explícita (`Z` o `±HH:MM`); una fecha
que no existe (30 de febrero) es inválida. Los enteros son enteros JSON, no
textos. Los límites usan el reloj del **servidor**:
`valid_until` en `(ahora, ahora + 24 h]`; `next_check_at` en
`[ahora − 60 s, valid_until]`.

El texto no lleva saltos de línea, espacios al borde ni caracteres de control,
y se rechaza (`sensitive_text`) si tiene forma de secreto, token o comando:
`` ` $ | ; < > \ { } ``, credenciales en una URL, `Bearer …`, `token=`,
`password:` y prefijos de tokens conocidos. Es una defensa, no una garantía:
el productor no debe enviar secretos, tokens, comandos ni logs.

### Cuerpo de `DELETE`

`epoch`, `expected_revision`, `owner`, `run_id` y `run_sequence`, con las
mismas reglas.

### Respuesta

Toda respuesta correcta (y `GET`) devuelve el documento completo:

```json
{
  "result": "created",
  "card": { "number": 2306, "board_id": "03gx…", "closed": false },
  "epoch": 0,
  "server_time": "2026-11-11T18:00:00.000000Z",
  "summary": {
    "waiting": true,
    "human": "not_required",
    "no_human_intervention_required": true,
    "next_check_at": "2026-11-11T18:03:00.000000Z",
    "presented_keys": ["ci:rails-test"]
  },
  "waits": [
    {
      "key": "ci:rails-test", "status": "active", "retired_reason": null, "retired_at": null,
      "presented": true, "producer": "ci", "state": "running", "owner": "dedalo:handy",
      "run_id": "ci-1", "run_sequence": 1, "reason": "CI de rails en ejecución",
      "expected_event": "Resultado del job rails-test", "human_condition": "not_required",
      "epoch": 0, "revision": 1,
      "next_check_at": "2026-11-11T18:03:00.000000Z", "valid_until": "2026-11-11T19:00:00.000000Z",
      "review": "scheduled", "freshness": "current", "updated_at": "2026-11-11T18:00:00.000000Z"
    }
  ]
}
```

`result` sólo aparece en una escritura: `created`, `updated`, `replayed` o
`cleared`. `waits` trae **todas** las filas, lápidas incluidas, en el orden de
la publicación. `status` es `active`, `cleared` (la limpió su owner) o
`retired` (la retiró la tarjeta; `retired_reason` es `closed`, `reopened` o
`board_changed`). `review` es `scheduled`, `due` (hasta 5 min después de la
fecha), `overdue` o `event_only`. `freshness` es `current` o `stale`.

### Códigos

| HTTP | `error` | Cuándo | Qué hace el productor |
|---|---|---|---|
| 200 | — | `updated`, `replayed`, `cleared`, o `GET` | Nada. |
| 201 | — | `created` | Nada. |
| 400 | — | JSON mal formado | Corregir el cuerpo. |
| 401 / 403 | — | Sin credencial, token de lectura, cuenta ajena | No reintentar igual. |
| 404 | — / `wait_not_found` | Tarjeta inaccesible; limpieza de una clave nunca declarada | No reintentar. |
| 409 | `epoch_mismatch` | La tarjeta se cerró, reabrió o cambió de tablero desde la lectura | Leer (`GET`) y decidir de nuevo. |
| 409 | `revision_mismatch` | Otro escritor cambió la fila (carrera o mensaje atrasado) | Leer y decidir de nuevo. |
| 409 | `stale_run` | `run_sequence` menor que el guardado | Descartar: es una ejecución anterior. |
| 409 | `run_conflict` | Misma `run_sequence` con otro `run_id` | Descartar. |
| 409 | `retired_run` | Reclamar una lápida con la misma ejecución | Usar una ejecución nueva. |
| 409 | `owner_mismatch` | Otro owner, o relevo sin `replaces_owner` correcto | No reintentar. |
| 409 | `already_retired` | Limpiar una espera que su owner ya limpió | Nada. |
| 409 | `card_closed` | Declarar en una tarjeta cerrada | No reintentar. |
| 413 | `body_too_large` | Más de 8 KiB | Corregir. |
| 415 | `json_required` | Otro tipo de contenido | Corregir. |
| 422 | `invalid` | `details`: lista de `{attribute, code}` (`unknown_property`, `missing`, `unknown_value`, `invalid_format`, `invalid_integer`, `invalid_text`, `sensitive_text`, `invalid_date`, `out_of_range`, `not_an_object`) | Corregir. Las propiedades ajenas se informan primero, solas. |
| 422 | `too_many_waits` | 20 esperas activas o 100 filas por tarjeta | Limpiar esperas. |

Un 409 trae `details` con la `revision` actual de la fila (si existe) y la
`epoch` actual de la tarjeta.

## Orden e idempotencia

Cada escritura toma el bloqueo de la tarjeta (un UPDATE de su fila
`card_automatic_wait_fences` antes de leer, que también bloquea SQLite) y
decide en este orden:

1. **Reintento idéntico.** Si la fila activa (o la lápida, en `DELETE`) se
   escribió con el mismo cuerpo y su revisión es `expected_revision + 1`, la
   respuesta es 200 `replayed` con la fila guardada. Nada cambia.
2. **Límites de fecha** (sólo `PUT`): `valid_until` y `next_check_at` contra
   el reloj del servidor, 422 `out_of_range`. Van después del paso 1: un
   reintento cuyas fechas ya pasaron sigue siendo `replayed`. El formato de la
   fecha se valida antes, sin bloqueo.
3. **Tarjeta cerrada** (sólo `PUT`): 409 `card_closed`.
4. **Época:** distinta de la actual, 409 `epoch_mismatch`.
5. **Revisión** (comparación atómica): distinta de la guardada (`0` si no
   existe), 409 `revision_mismatch`.
6. **Owner y ejecución:** ver abajo.
7. Escribe, con revisión + 1, la época actual y el tablero actual.

La fecha del cliente nunca ordena: el orden es época, revisión y
`run_sequence`. `updated_at` es del servidor.

## Owner, relevo y ejecuciones retiradas

- Con el mismo owner, `run_sequence` sólo avanza: menor es `stale_run`; igual
  con otro `run_id` es `run_conflict`; mayor es el relevo de ejecución.
- Otro owner sólo releva si nombra al actual en `replaces_owner` **y** trae
  una `run_sequence` mayor. Después, el owner anterior recibe
  `owner_mismatch` en toda escritura y limpieza: la limpieza por otro owner se
  rechaza.
- `DELETE` deja una **lápida**: la fila conserva owner, ejecución y revisión.
  Volver a declarar esa clave exige una `run_sequence` mayor que la de la
  lápida (`retired_run` si no). La protección sigue después de limpiar el
  indicador.

## Cierre, reapertura y cambio de tablero

Cerrar, reabrir o mover la tarjeta a otro tablero, en la misma transacción:
avanza la época de la tarjeta y retira todas las esperas activas
(`retired_reason`), con revisión + 1. Un productor que leyó antes recibe
`epoch_mismatch` en **cualquier** clave, también en una que nunca declaró. La
fila de protección no se borra mientras exista la tarjeta.

Un pendiente humano no se pierde: una espera retirada por la tarjeta con
`human_condition` `required` o `pending` se sigue mostrando («Seguimiento
retirado: …» y la condición humana) hasta que su owner declare o limpie esa
clave otra vez. La limpieza de una espera retirada por la tarjeta es válida,
también con la tarjeta cerrada: el owner lee la época y la revisión actuales y
envía `DELETE`. Retirar nunca reanuda trabajo ni implica éxito.

## Reinicio del productor

Fizzy no guarda nada en memoria del productor. Después de un reinicio, el
productor lee `GET`, toma `epoch` y la `revision` de cada clave, y sigue. Lo
que recordaba antes del reinicio recibe 409 si la tarjeta cambió.

## Publicación agregada y presentación

Orden determinista de `waits`: condición humana (`required`, `pending`,
`unknown`, `not_required`), activas antes que retiradas, próxima revisión más
cercana (sin fecha al final) y clave. Se conservan todos los motivos.

`summary.human`, con esta precedencia:

1. `required` — alguna espera lo declara: «Requiere intervención humana».
2. `pending` — «Hay una decisión humana pendiente».
3. `stale` — alguna espera pasó su vigencia: «Seguimiento desactualizado».
4. `unknown` — alguna sin evidencia: «Sin evidencia sobre intervención humana».
5. `not_required` — **todas** vigentes y con `not_required` explícito: «No
   requiere intervención humana». La ausencia de aprobación no es una espera
   sana: sólo esta evidencia explícita la muestra.

La **revisión vencida** (`due`, `overdue`) y la **vigencia vencida**
(`stale`) son cosas distintas. Ninguna implica éxito, reintento ni permiso para
reanudar; sólo `required` declara intervención requerida.

En la tarjeta compacta, un reloj encima del contador de comentarios, también
con cero comentarios. Hover, foco, teclado (Enter o Espacio fija, Escape
cierra) y toque muestran «Esperando al sistema», la condición humana y todos
los motivos: «Próxima revisión en aproximadamente 3 min» con fecha (la fecha
no es un pronóstico de fin), «Espera: <evento>» sin fecha, y en cero
«Revisión pendiente» y luego «Revisión vencida». El indicador se conserva
hasta una actualización válida. El navegador recalcula esos textos cada 15 s
con las mismas reglas que `AutomaticWaitsHelper`.

Una escritura toca `updated_at` de la tarjeta (no `last_active_at`): la
tarjeta y su tablero se refrescan por Cable, sin recargar y sin duplicar el
control. Fizzy no publica comentarios ni eventos por las esperas.

## Verificación para Dédalo

```bash
FIZZY=https://hermes.tailbaa835.ts.net:43008/1
CARD=2306
# El token lo da Dédalo desde su credencial gestionada; nunca lo imprimas.

# Leer el estado y la época
curl -sS -H "Authorization: Bearer $FIZZY_TOKEN" -H "Accept: application/json" \
  "$FIZZY/cards/$CARD/automatic_waits"

# Declarar (expected_revision 0 para una clave nueva; epoch de la lectura)
curl -sS -X PUT -H "Authorization: Bearer $FIZZY_TOKEN" -H "Content-Type: application/json" \
  "$FIZZY/cards/$CARD/automatic_waits/ci:rails-test" -d '{
    "epoch": 0, "expected_revision": 0, "owner": "dedalo:handy",
    "run_id": "ci-4182", "run_sequence": 4182, "producer": "ci", "state": "running",
    "reason": "CI de rails en ejecución", "expected_event": "Resultado del job rails-test",
    "next_check_at": "2026-11-11T18:03:00Z", "valid_until": "2026-11-11T19:00:00Z",
    "human_condition": "not_required"}'

# Releer y comprobar revision, status y summary.human; después limpiar
curl -sS -X DELETE -H "Authorization: Bearer $FIZZY_TOKEN" -H "Content-Type: application/json" \
  "$FIZZY/cards/$CARD/automatic_waits/ci:rails-test" -d '{
    "epoch": 0, "expected_revision": 1, "owner": "dedalo:handy",
    "run_id": "ci-4182", "run_sequence": 4182}'
```

Para el fork, las pruebas del contrato:

```bash
SAAS=false BUNDLE_GEMFILE=Gemfile bin/rails test \
  test/models/card/automatic_wait test/controllers/cards/automatic_waits_controller_test.rb
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 bin/rails test test/system/automatic_waits_test.rb
```

## Fuera de alcance

- Los productores, la publicación desde CI::Queue, Monitor::Runner y el tick
  de Dédalo, y la verificación de la integración real.
- Exportar e importar esperas entre instancias: son estado de un productor
  externo y no viajan en `Account::DataTransfer`.
- Mostrar el reloj en la vista completa de la tarjeta.
