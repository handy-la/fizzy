# Filtros: los términos de búsqueda tienen límite

## Autoría antes de editar las pruebas

Base productiva: `f25c72da9ba17a7f184fa2c29673ad3670ff0546` (incluye la
revisión auditada `25a93b13ec5a819fed72f956b64f7da424b5a852`).

- **Contrato:** un filtro acepta como máximo `MAX_TERMS` (10) términos, cada
  uno de hasta `MAX_TERM_LENGTH` (100) caracteres y con un total de hasta
  `MAX_TERMS_LENGTH` (300). Los términos se normalizan (`squish`, sin vacíos)
  y se deduplican. Guardar un filtro que excede el límite falla; un filtro
  guardado antes del límite no construye predicados de texto completo y no
  muestra tarjetas. Cada término aceptado agrega un solo predicado `MATCH`.
  Dueños: `Filter::Fields`, `Filter#cards`, `Filter::Params.normalize_params`,
  `FiltersController#create` y `FilterScoped#set_filter`. Fronteras: el modelo
  (`valid?`, `save!`, el SQL de `Filter#cards`) y HTTP (`POST /filters`,
  `GET /cards` con `terms[]` o con `filter_id`).
- **Regresión:** quitar la validación permite guardar miles de términos;
  quitar la comprobación de `Filter#cards` construye un `MATCH` por cada
  término de un filtro antiguo (500 en la prueba); quitar la respuesta 422 de
  `FilterScoped` ejecuta la consulta de un filtro que excede el límite; volver a
  `Array(value).filter(&:present?)` conserva duplicados y espacios.
- **Cobertura:** `filter_test.rb` sólo comprobaba `terms` vacío y un término;
  `filter/search_test.rb` comprueba el resultado de uno y dos términos, sin
  límite. Ningún caso del controlador enviaba términos. Los casos nuevos
  amplían los tres archivos existentes; las dos capas protegen riesgos
  distintos (persistencia y SQL en el modelo; código HTTP en el controlador).
- **Seam:** ninguno de prueba. `Filter#terms_within_limits?` y las constantes
  tienen consumidores productivos: `Filter#cards`, la validación y
  `FilterScoped`. La prueba de SQL cuenta `MATCH` en `Filter#cards.to_sql`, la
  relación que paginan `CardsController`, `BoardsController` y
  `Cards::PreviewsController`.

Casos nuevos:

- `filter_test.rb`: normalización y deduplicación; rechazo de 11 términos;
  rechazo de un término de 101 caracteres y de un total de 1000; un filtro
  guardado con 500 términos no muestra tarjetas ni construye `MATCH`; un filtro
  antiguo sigue guardándose cuando se borra una etiqueta; 10 términos
  construyen 10 `MATCH`.
- `filters_controller_test.rb`: `POST /filters` con 11 términos responde 422 y
  no crea un filtro.
- `cards_controller_test.rb`: `GET /cards` con 11 términos y con el
  `filter_id` de un filtro antiguo de 500 términos responden 422.

Dos casos pasan en la base y no son regresiones de la tarjeta:

- «an accepted filter builds one search predicate per term» fija la cota
  superior de la paginación que pide la tarjeta (10 términos, 10 predicados).
- «a persisted filter over the limit still saves when a resource is removed»
  protege contra una regresión de este cambio: `Filter#resource_removed` usa
  `save!`, y una validación sin condición haría fallar el borrado de una
  etiqueta o un tablero. Sensibilidad comprobada: sin `if: :fields_changed?`
  la prueba falla con `ActiveRecord::RecordInvalid` en
  `app/models/filter/resources.rb:16`.

## Decisiones

- El límite de un filtro antiguo se aplica al leer: `Filter#cards` devuelve
  `none` y `FilterScoped` responde 422. El filtro no se borra; la persona lo
  puede eliminar desde la lista de filtros.
- No se combinan los términos en una sola consulta: cada adaptador de
  ActiveSearch (FTS5 en SQLite, MySQL sharded) interpreta la sintaxis de otra
  forma. Con 10 términos la consulta queda acotada.

## Evidencia

SHA-256 de los archivos de prueba, iguales en RED y GREEN:

| Archivo | SHA-256 |
|---|---|
| `test/models/filter_test.rb` | `1fb4567c7ae1c07a3e36467de561263289e2570a6dd5c0e146fd1988bbf43ec6` |
| `test/controllers/filters_controller_test.rb` | `455f80291b23d1769eb943454531872d2c9209820dd11ccaa84daa213503d2ab` |
| `test/controllers/cards_controller_test.rb` | `039116256c8726034b0372299b8988056b35347b5438812778b4a7b57b3b96d8` |

Comando, desde `fizzy-custom/`, con Ruby 3.4.8 de mise y SQLite. RED corrió con
`app/` de la base (`git checkout app`) y las pruebas nuevas encima:

```bash
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/models/filter_test.rb \
  test/controllers/filters_controller_test.rb test/controllers/cards_controller_test.rb
```

RED (base): `62 runs, 288 assertions, 7 failures, 0 errors`, código 1.

- `create rejects too many terms`: el conteo de filtros cambió en 1.
- `a persisted filter over the limit matches no cards…`: `Expected: 0,
  Actual: 500` predicados `MATCH`.
- `terms are normalized and deduplicated`: conserva espacios y duplicados.
- `rejects too many terms` y `rejects a term or a total…`: el filtro es válido.
- `index rejects too many terms` y `index rejects a persisted filter…`:
  respuesta 200 en lugar de 422.

GREEN (cambio): `62 runs, 292 assertions, 0 failures, 0 errors`, código 0.
Suite completa (`SAAS=false BUNDLE_GEMFILE=Gemfile bin/rails test`): 1808
pruebas, 0 fallos, 0 errores, 6 omitidas. No verifiqué el adaptador MySQL.
