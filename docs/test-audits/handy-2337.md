# Revisión vencida con la evidencia vigente: pruebas complementarias — Handy 2337

Base del fork: `013bf8d610933761a5b353ebf8205ee360282e22`. Esa base ya
contiene la corrección del validador (Handy #2314, caso residual de Dédalo
#2302): `next_check_at` sólo tiene el límite `<= valid_until`. Este lote **no
cambia código**: agrega dos pruebas y dos viñetas del contrato
([`docs/automatic-waits.md`](../automatic-waits.md), sección «Evidencia
vencida y pendientes humanos»). Arturo eligió este alcance en la tarjeta
(opción 1, 2026-11-12). Fichas anteriores: [`handy-2306.md`](handy-2306.md) y
[`handy-2314.md`](handy-2314.md). Correlación:
`dedalo-2302-fizzy-overdue-review-20261112`.

## Reproducción de la tarjeta

La tarjeta da `next_check_at` 05:58:00Z, `valid_until` 06:05:00Z y la hora del
servidor 06:00:00Z. La prueba del modelo usa la misma forma con el reloj de la
suite (18:00:00Z): 17:58:00Z y 18:05:00Z. La prueba del controlador usa
17:50:00Z, más allá de la ventana `due`, para cubrir `overdue` en la frontera
JSON.

## Autoría antes de editar pruebas

### Prueba nueva en `test/models/card/automatic_wait/declaration_test.rb`

Caso: «a first write that arrives after its next check keeps both dates, and
its expiry writes nothing».

- **Contrato:** `Card::AutomaticWait::Declaration` acepta el **primer** envío
  (`created`) con `next_check_at` pasado y `valid_until` futuro, y guarda las
  dos fechas como llegan. El `pending` de ese envío prevalece en
  `Summary#human`; `not_required` lo devuelve a `not_required` con las mismas
  fechas. Al pasar `valid_until` la fila queda `stale` y `overdue`, y
  `Summary#human` es `stale`, sin otra escritura (la revisión sigue en 2).
  Dueño: `validate_time_ranges`; frontera: modelo, base de datos y `Summary`.
- **Regresión:** volver a exigir `next_check_at ≥ ahora − 60 s` con evidencia
  vigente; aplicar un límite sólo a la creación (por ejemplo, validar el
  `next_check_at` de una clave nueva contra el reloj); normalizar
  `next_check_at` o renovar `valid_until`; escribir algo al vencer la
  vigencia.
- **Cobertura:** «a human update on current evidence keeps its original next
  check, already past» (Handy #2314, `013bf8d61`) crea la espera con una
  revisión **futura** y sólo después la actualiza con la revisión pasada:
  cubre el camino `updated`, no el primer envío tardío, y no recorre el
  vencimiento de `valid_until`. Esa prueba ya cubre `revision_mismatch` y
  `run_conflict` en este camino, por eso este caso no los repite.
- **Seam:** ninguno. `travel_to`/`travel` para el reloj, como en 2306.

### Prueba nueva en `test/controllers/cards/automatic_waits_controller_test.rb`

Caso: «a late first write keeps its overdue review and current evidence».

- **Contrato:** por la API, el `PUT` contesta 201 y publica las dos fechas
  originales, `freshness: "current"`, `review: "overdue"`, `summary.human`
  `pending` y `summary.next_check_at` nulo (sólo publica revisiones futuras).
- **Regresión:** un 422 `out_of_range` en la frontera HTTP; una serialización
  que cambie la fecha o marque la fila `stale`; un `summary.next_check_at` que
  publique una revisión pasada como próxima.
- **Cobertura:** la corrección de `013bf8d61` sólo se prueba en el modelo. La
  prueba de 2314 en el controlador publica evidencia vencida (`stale`).
- **Seam:** ninguno.

No se cambia ni se retira ninguna prueba: la fila `next_check_at 17:58 →
out_of_range` ya la retiró `013bf8d61`, con su ficha en `handy-2314.md`.

## RED y GREEN

Directorio `fizzy-custom/`, Ruby 4.0.9 de mise primero en el `PATH`, sin
`GEM_HOME`/`GEM_PATH`/`RUBYOPT`/`BUNDLE_GEMFILE` heredados,
`SAAS=false BUNDLE_GEMFILE=Gemfile`:

```bash
bin/rails test test/models/card/automatic_wait test/controllers/cards/automatic_waits_controller_test.rb
```

- **RED:** la base de este lote ya trae la corrección, así que el RED usa el
  `declaration.rb` anterior a ella,
  `11e2216a0098db1dd5bc9e795ccf75cb4acfce71` (restaurado en el archivo con
  `git show 11e2216a0:app/models/card/automatic_wait/declaration.rb`, sin otra
  edición, y devuelto después a `013bf8d61`), con las pruebas de este lote.
  Salida 1: 47 casos, 247 aserciones, 3 fallos, todos por la causa de la
  tarjeta: las dos pruebas nuevas (`Actual: :invalid`; `Expected 201, was
  422` con `{"attribute":"next_check_at","code":"out_of_range"}`) y la prueba
  de 2314 del mismo contrato.
- **GREEN:** el mismo comando sobre `013bf8d61` con este lote, salida 0:
  47 casos, 270 aserciones, 0 fallos.

## No verificado

- La integración real Dédalo → API → tarjeta (fuera de alcance).
- No hay una prueba de sistema con una revisión vencida sobre evidencia
  vigente; la vista ya muestra «Revisión pendiente» y «Revisión vencida» según
  `next_check_at`, con las mismas reglas en el navegador.
