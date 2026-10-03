# Sugerencia de comentario: pedir al agente que ejecute los comandos — Handy 605

`Card::Suggestion#comment` recibe una instrucción nueva. Cuando los últimos
comentarios dicen que quedan comandos o procesos por correr a mano, la
sugerencia termina con una petición al agente: que ejecute él esos comandos y
no espere a una persona. No cambia marcado, estilos ni textos de pantalla.

## Contrato de la prueba modificada

Se amplía `test "comment includes all history and creates no comment"` en
`test/controllers/cards/suggestions_controller_test.rb` con una aserción.

- **Contrato:** las instrucciones que se envían al proveedor incluyen la
  petición de que el agente ejecute los comandos pendientes. El dueño es
  `Card::Suggestion#comment`; la frontera es el mensaje HTTP al proveedor,
  interceptado por `stub_completion` (WebMock). Un prompt es un contrato de
  bytes, según la barra de retención de `test-audit`.
- **Regresión:** borrar o reescribir la instrucción hace que Fizi deje de
  sugerir esa petición, sin otro error visible. La aserción falla.
- **Cobertura:** el mismo caso ya comprueba las otras frases del prompt
  (`authorizing those commands`, `Do not invent facts`). Ninguna prueba
  comprobaba esta instrucción. Se amplía el caso existente porque cubre el
  mismo riesgo; una prueba nueva duplicaría la preparación.
- **Seam:** no hace falta. La prueba lee la petición HTTP real al proveedor.

No se prueba la respuesta del modelo: depende del proveedor y no es
determinista.

## Evidencia RED y GREEN

Base de `fizzy-custom`: `c706f0c2a92dff7f06a63b842a5290aa0c860c5e`.

Comando, desde `fizzy-custom/`, sin variables heredadas de Ruby/Bundler:

```bash
SAAS=false BUNDLE_GEMFILE=Gemfile mise exec -- bin/rails test \
  test/controllers/cards/suggestions_controller_test.rb -i "/comment includes all history/"
```

- **RED** (prueba nueva, `app/models/card/suggestion.rb` de la base):
  `1 tests, 13 assertions, 1 failures`, código de salida 1. Causa: `Expected "Suggest one
  simple, brief reply …" to include "asking the agent to run those commands
  itself instead of waiting for a person"` en la línea 44.
- **GREEN** (con el cambio): `1 tests, 47 assertions, 0 failures`, código de
  salida 0.
- `suggestions_controller_test.rb` y `card_suggestion_channel_test.rb`
  completos: `14 tests, 186 assertions, 0 failures`.
