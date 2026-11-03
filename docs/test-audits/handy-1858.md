# Duplicar otra vez el presupuesto global de sugerencias (Handy #1858)

## Cambio

Handy #1157 subió el presupuesto global de sugerencias con IA de treinta a
sesenta por hora. Esta tarjeta pide duplicarlo otra vez.
`Card::SuggestionQueue::GLOBAL_BUDGET` pasa de 60 a 120. El Fizzy de la caja
corre con `MULTI_TENANT=false` y sin `AI_SUGGESTION_*_BUDGET` (comprobado en el
contenedor `handy-fizzy-local-fizzy-1` el 2026-11-03), así que su única cuenta
usa ese valor predeterminado.

No cambia: el presupuesto por cuenta en modo multiinquilino (diez), los
límites de concurrencia (uno por usuario, dos por cuenta, cuatro globales), el
`rate_limit` del controlador (diez por minuto por usuario) ni las variables de
entorno.

## Autoría antes de editar pruebas

Base: `6cda7f158a9ae27053fe3ae9d4ca83ccd8427e8e`.

- **Contrato:** sin `MULTI_TENANT`, la única cuenta admite ciento veinte
  sugerencias por hora y rechaza la siguiente; con varias cuentas, rotar
  cuentas no pasa de ciento veinte globales. Dueño:
  `Card::SuggestionQueue#reserve`. Frontera: filas de reserva y llamadas HTTP
  al proveedor.
- **Regresión:** dejar el tope global en sesenta, o cambiar sólo uno de los dos
  modos.
- **Cobertura:** se amplían los dos casos que ya fijaban sesenta en
  `test/models/card/suggestion_queue_test.rb`: «single-tenant installation
  gives its only account the global budget» (ciento veinte llamadas) y «global
  hourly budget cannot be avoided by rotating accounts» (doce cuentas de diez).
  No se agrega un caso nuevo.
- **Seam:** ninguno nuevo.

## Evidencia RED y GREEN

SHA-256 de `test/models/card/suggestion_queue_test.rb`, igual en RED y GREEN:
`ef02b5d556aee18cc3fef720ca6f9807c4d50c2dc80c0b53600b7229084c5807`.

Comando desde `fizzy-custom/`, con el Ruby 4.0.9 de mise al frente del `PATH`
(`mise exec` resolvía el Ruby 3.4 del sistema en esta caja):

```bash
env -u GEM_HOME -u GEM_PATH -u BUNDLE_GEMFILE -u RUBYOPT -u BUNDLE_PATH \
  PATH=$HOME/.local/share/mise/installs/ruby/4.0.9/bin:$PATH \
  SAAS=false BUNDLE_GEMFILE=Gemfile bin/rails test \
  test/models/card/suggestion_queue_test.rb
```

- **RED** (base, con las pruebas ampliadas): código 1; 9 pruebas, 2 errores.
  Los dos casos ampliados lanzan `Card::SuggestionQueue::Full` en la llamada 61
  (`app/models/card/suggestion_queue.rb:59`).
- **GREEN** (con `GLOBAL_BUDGET = 120`): código 0. Junto con
  `test/controllers/cards/suggestions_controller_test.rb`,
  `test/models/card/suggestion_test.rb` y
  `test/models/card/suggestion_admission_concurrency_test.rb`: 32 pruebas,
  309 aserciones, 0 fallos.
