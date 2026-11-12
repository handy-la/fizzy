# Mismo orden de comentarios en la cola y en la revalidación (Handy #2355)

Base del repo dueño: `5ddd390b99922c59fbaa3b372774615faf9beb97` (`origin/main`
de `fizzy-custom`, con Handy #2304). Hallazgo no bloqueante de la ronda 5 de
`bin/signoff` de Handy #2304.

## Causa

`Board::PowerThrough#entries` pasaba los comentarios ordenados por
`[created_at, id]` ascendente. `Card::PendingRequest.for` sin comentarios usaba
`Comment.chronologically` (`created_at` ascendente, `id` descendente), en el
JSON de revalidación y en la página cuando la tarjeta enfocada no está en la
cola. Con dos comentarios de la misma fecha, los dos lectores recorren otro
orden, dan otro veredicto y otra huella. La página muestra la huella de la
cola; el envío la compara con la del JSON y avisa «La solicitud cambió» sin un
cambio real.

## Corrección

El orden vive sólo en `Card::PendingRequest#initialize`: `created_at` y después
`id`, los dos ascendentes, sobre cualquier colección que reciba.
`Board::PowerThrough` pasa los comentarios precargados sin ordenar.
`Comment.chronologically` no cambia: es de upstream y otras vistas lo usan.

## Autoría antes de editar pruebas

### `test/controllers/boards/power_throughs_controller_test.rb` (ampliado)

Caso: «a question and its answer at the same instant read the same in the page
and in the card state».

- **Contrato:** la huella y el estado que la página entrega al compositor
  (`#power_through_state`, construido desde la cola) son los mismos que
  responde el JSON de revalidación para la misma tarjeta sin cambios, también
  cuando dos comentarios comparten `created_at`. Dueños:
  `Card::PendingRequest` (orden del recorrido) y sus dos consumidores. Frontera:
  HTML de la página y JSON de `board_power_through_card_path`.
- **Regresión:** cualquier consumidor que vuelva a ordenar por su cuenta en
  otro sentido (por ejemplo `Comment.chronologically` en `for`). La prueba fija
  ids explícitos y ordenados (respuesta menor que pregunta), porque los UUIDv7
  de ejecución pueden invertir el orden dentro del mismo milisegundo.
- **Cobertura:** `the card state answers the current verdict and fingerprint`
  compara el JSON con `PendingRequest.for` (el mismo camino), no con la página
  ni con la cola; las pruebas de `pending_request_test.rb` y
  `power_through_test.rb` usan fechas distintas por comentario.
- **Seam:** ninguno. La prueba usa las rutas reales.

## RED y GREEN

Desde `fizzy-custom/`, Ruby 4.0.9 de mise (`PATH="$(mise where ruby)/bin:$PATH"`,
sin `GEM_HOME`, `GEM_PATH` ni `BUNDLE_PATH` heredados), SQLite:

```
SAAS=false BUNDLE_GEMFILE=Gemfile bin/rails test \
  test/controllers/boards/power_throughs_controller_test.rb -n "/same instant/"
```

- **RED** sobre `5ddd390b9` con sólo la prueba nueva: salida 1,
  `Expected: "pending"`, `Actual: "none"` en la comparación con el JSON. La
  página (cola) ve la pregunta abierta y el JSON la ve contestada: la causa del
  hallazgo, no un error de carga.
- **GREEN** con la corrección: salida 0. Los tres archivos de Power Through
  (`power_throughs_controller_test.rb`, `pending_request_test.rb`,
  `power_through_test.rb`): salida 0, «40 tests, 0 failures».
- Suite completa con la corrección:
  `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=4 bin/rails test`:
  salida 0, «3235 tests, 17937 assertions, 0 failures, 0 errors, 5 skips».
  `bin/rubocop` sobre los tres archivos Ruby: sin infracciones.
