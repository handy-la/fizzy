# El aviso de la siguiente tarjeta ofrece la de hasta abajo de la etapa

## Cambio

Al mover o cerrar una tarjeta desde su página, el aviso «Next in <etapa>»
ofrecía la primera tarjeta de la etapa de origen: la de hasta arriba de la
columna (doradas primero, después la de actividad más reciente). La persona
pidió la de hasta abajo. `cards/_next_in_stage.html.erb` toma ahora la última
del mismo orden que muestra el tablero (`latest.with_golden_first.last`). El
orden invertido que genera Rails es
`card_goldnesses.id IS NULL DESC, last_active_at ASC, id ASC`: una tarjeta
dorada sólo sale si todas las de la etapa son doradas.

`Column::Approval#next_card_awaiting` no cambia: ninguna vista ni controlador
lo usa.

## Autoría antes de editar pruebas

Base: `bd39865572332ff3a6f19c628e3988b7001d42e5`.

- **Contrato:** el aviso enlaza la tarjeta activa de la etapa de origen que
  queda al final del orden de la columna: no dorada antes que dorada, la de
  actividad más antigua, y nunca la tarjeta que se movió. Dueño:
  `cards/_next_in_stage.html.erb`, que usan `CardsController`,
  `Cards::TriagesController`, `Cards::ClosuresController` y
  `Cards::NotNowsController`. Frontera: el HTML de la página de la tarjeta.
- **Regresión:** volver a `.first` (la de hasta arriba), quitar
  `with_golden_first` o cambiar `latest` por otro orden.
- **Cobertura:** las pruebas de `card_dock_test.rb` y
  `card_stage_navigation_test.rb` dejan una sola tarjeta candidata en la etapa
  de origen, así que no distinguen arriba de abajo. Sólo «moving from Maybe»
  tenía dos candidatas, y fijaba la dorada de arriba: se cambia su esperado a
  la de abajo. Se agrega «the toast offers the card at the bottom of the source
  stage» con tres candidatas en una columna (una dorada, una reciente y una
  antigua).
- **Seam:** ninguno. Las pruebas usan las rutas reales de mover una tarjeta.

## Evidencia RED y GREEN

Directorio `fizzy-custom/`, Ruby de mise, sin variables heredadas de RVM:

```bash
env -u GEM_HOME -u GEM_PATH -u BUNDLE_GEMFILE -u RUBYOPT -u BUNDLE_PATH -u RUBYLIB \
  SAAS=false BUNDLE_GEMFILE=Gemfile mise exec -- \
  bin/rails test test/integration/card_dock_test.rb -n "/bottom of/"
```

- **RED** con la vista de la base y las pruebas nuevas: exit 1, dos fallos,
  `Expected at least 1 element matching ".approval-toast a[href=\"/897362094/cards/5\"]", found 0.`
  La base ofrecía la dorada de hasta arriba.
- **GREEN** con el mismo comando sobre el cambio (commit `94acd8c8a`): exit 0,
  `2 tests, 10 assertions, 0 failures, 0 errors, 0 skips`.
- Con el mismo entorno, `bin/rails test test/integration/card_dock_test.rb
  test/system/card_stage_navigation_test.rb test/models/column/approval_test.rb`
  da exit 0 con 21 pruebas y 0 fallos, y `bin/rails test` da exit 0 con
  2154 pruebas, 0 fallos y 0 errores.
