# Presupuesto de sugerencias en una instalación de un solo inquilino

## Causa

`Card::SuggestionQueue` reservaba diez llamadas por cuenta y treinta globales
por hora. El Fizzy local corre con `MULTI_TENANT=false` y tiene una sola
cuenta: diez sugerencias por hora alcanzaban para todas las personas. Al
agotarse, el POST devolvía 429 con `Retry-After: 90` y el navegador mostraba
«No se pudo obtener la sugerencia.» sin leer la cabecera.

La sugerencia de comentario ya no se pide al abrir una tarjeta: exige foco
por puntero, Tab o el toque de un celular (`docs/test-audits/handy-571.md`).
Esta tarjeta no cambia ese disparo. Tampoco reparte el presupuesto por usuario:
eso exige guardar el usuario en cada reserva, y el límite de una solicitud
activa por usuario ya impide que una persona acumule trabajo en paralelo.

## Autoría antes de editar pruebas

Base: `19fbba501187e7c0cdeec81974fb43beff007c5f`.

- **Contrato:** con `MULTI_TENANT` apagado, la única cuenta admite hasta el
  presupuesto global por hora; las variables `AI_SUGGESTION_ACCOUNT_BUDGET` y
  `AI_SUGGESTION_GLOBAL_BUDGET` cambian ambos topes. Un 429 por presupuesto
  dice en `Retry-After` cuándo vence la reserva más antigua, y el navegador
  muestra el cupo agotado con los minutos de espera. Dueños:
  `Card::SuggestionQueue#reserve`, `Cards::SuggestionsController#create` y
  `ai_suggestion_controller.js`. Fronteras: filas de reserva, HTTP y DOM.
- **Regresión:** volver a fijar diez por cuenta sin mirar el modo de inquilinos;
  ignorar las variables; responder siempre `Retry-After: 90`; tratar el 429
  como un error genérico en el navegador.
- **Cobertura:** `suggestion_queue_test.rb` probaba diez por cuenta y treinta
  globales sólo en modo multiinquilino (el de `config/environments/test.rb`).
  `suggestions_controller_test.rb` comprueba el estado 429 de capacidad, no la
  cabecera del presupuesto. `ai_suggestion_test.rb` cubre fallos `failed`, no
  un 429. Se amplían esos tres archivos con un caso cada uno (dos en el modelo).
- **Seam:** ninguno nuevo. Las pruebas cambian `Account.multi_tenant` y `ENV`,
  que son la configuración productiva, y restauran ambos al terminar.
  `Card::SuggestionQueue::Full#retry_after` sirve al controlador.

## Evidencia RED y GREEN

Las pruebas se escribieron sobre la base, sin el arreglo, en este worktree.
SHA-256 de los candidatos, iguales en RED y GREEN:

| Archivo bajo `test/` | SHA-256 |
|---|---|
| `models/card/suggestion_queue_test.rb` | `3239e9d3c0aa3aa9679945b7f53236dd1cb27ab5fb9915763aafd17892459f34` |
| `controllers/cards/suggestions_controller_test.rb` | `a36c1840afeafb6f7a75b23e1c4c23957cea7429e389be67486d20c3fe2e12ca` |
| `system/ai_suggestion_test.rb` | `cdc55c5e5b587023f0c9724ceff69d1b49de9ef787de8862d4c1d38de410c410` |

Comando desde `fizzy-custom/`, con Ruby de mise 3.4.8:

```bash
env -u GEM_HOME -u GEM_PATH -u BUNDLE_GEMFILE -u RUBYOPT -u BUNDLE_PATH \
  SAAS=false BUNDLE_GEMFILE=Gemfile mise exec -- bin/rails test \
  test/models/card/suggestion_queue_test.rb \
  test/controllers/cards/suggestions_controller_test.rb
# y, por separado:
#   ... bin/rails test test/system/ai_suggestion_test.rb -n "/exhausted quota/"
```

RED: 26 casos, dos fallos y un error. La undécima admisión de una cuenta
única levanta `Card::SuggestionQueue::Full`; con las variables a 3 y 4 la
cuarta admisión se acepta; la cabecera es `"90"` en vez de `"600"`. El caso
de sistema encuentra «No se pudo obtener la sugerencia.» en lugar del cupo.

GREEN: los mismos comandos pasan sin fallos ni errores.

## Validación

Con el mismo Ruby limpio, `SAAS=false`, `BUNDLE_GEMFILE=Gemfile` y
`CI_PROGRESS_BAR=false`:

| Comando en `fizzy-custom/` | Resultado |
|---|---|
| `PARALLEL_WORKERS=4 mise exec -- bin/rails test` | Salida 0; 2.153 casos, 9.289 aserciones, seis omisiones |
| `PARALLEL_WORKERS=1 mise exec -- bin/rails test:system` | Salida 0; 64 casos, 454 aserciones, sin omisiones |
| `mise exec -- bin/rubocop -f simple` sobre los cinco archivos Ruby del diff | Sin infracciones |
| `mise exec -- ruby script/check_agents_docs` | Salida 0 |

## Lo que no se verificó

No se llamó al proveedor real ni se desplegó. No se probó MySQL ni el modo
SaaS. En una corrida conjunta con más carga, cuatro casos antiguos de
`ai_suggestion_test.rb` dieron error; el archivo completo pasó dos veces
seguidas después, sin cambios.
