# Duplicar el presupuesto global de sugerencias (Handy #1157)

## Cambio

Handy #999 dio a la única cuenta de una instalación sin `MULTI_TENANT` el
presupuesto global: pasó de diez a treinta sugerencias por hora. Esta tarjeta
pide duplicarlo otra vez. `Card::SuggestionQueue::GLOBAL_BUDGET` pasa de 30 a
60. El Fizzy de la caja corre con `MULTI_TENANT=false` y sin
`AI_SUGGESTION_*_BUDGET` (comprobado en el contenedor el 2026-10-16), así que
usa ese valor predeterminado.

No cambia: el presupuesto por cuenta en modo multiinquilino (diez), los
límites de concurrencia (uno por usuario, dos por cuenta, cuatro globales) ni
las variables de entorno.

## Autoría antes de editar pruebas

Base: `7df9e6ce9363825003cda48987fbbe8e019f2965`.

- **Contrato:** sin `MULTI_TENANT`, la única cuenta admite sesenta sugerencias
  por hora y rechaza la siguiente; con varias cuentas, rotar cuentas no pasa de
  sesenta globales. Dueño: `Card::SuggestionQueue#reserve`. Frontera: filas de
  reserva y llamadas HTTP al proveedor.
- **Regresión:** dejar el tope global en treinta, o cambiar sólo uno de los dos
  modos.
- **Cobertura:** se amplían los dos casos que ya fijaban treinta en
  `test/models/card/suggestion_queue_test.rb`: «single-tenant installation
  gives its only account the global budget» (sesenta llamadas) y «global hourly
  budget cannot be avoided by rotating accounts» (seis cuentas de diez). No se
  agrega un caso nuevo.
- **Seam:** ninguno nuevo.

## Evidencia RED y GREEN

SHA-256 de `test/models/card/suggestion_queue_test.rb`, igual en RED y GREEN:
`2939ab21b615cfdda55c6f23ee49f52ec88e1a29adac40341e24dc467a4a6eab`.

Comando desde `fizzy-custom/`, con Ruby de mise:

```bash
env -u GEM_HOME -u GEM_PATH -u BUNDLE_GEMFILE -u RUBYOPT -u BUNDLE_PATH \
  SAAS=false BUNDLE_GEMFILE=Gemfile mise exec -- bin/rails test \
  test/models/card/suggestion_queue_test.rb
```

- **RED** (base, con las pruebas nuevas): código 1; 9 pruebas, 2 errores. Los
  dos casos ampliados lanzan `Card::SuggestionQueue::Full` en la llamada 31.
- **GREEN** (con `GLOBAL_BUDGET = 60`): código 0. Junto con
  `test/controllers/cards/suggestions_controller_test.rb` y
  `test/models/card/suggestion_test.rb`: 30 pruebas, 0 fallos.
