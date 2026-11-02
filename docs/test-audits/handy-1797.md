# Handy 1797: contexto opcional de tarjetas citadas

## Autoría previa a las pruebas

1. **Contrato:** `Card::Suggestion#comment` ofrece al proveedor una herramienta
   opcional para leer tarjetas citadas en los comentarios de la tarjeta actual.
   La lectura devuelve descripción, comentarios, pasos y estado. Sólo permite
   tarjetas de la cuenta visibles para quien pide la sugerencia. No escribe.
   La frontera observada es HTTP Chat Completions y la base real de fixtures.
2. **Regresión:** quitar la herramienta, omitir su resultado, consultar por número
   sin permisos, seguir referencias de segundo nivel o repetir herramientas sin
   límite viola este contrato. Las respuestas HTTP controladas eligen llamar o
   no llamar la herramienta; no implementan la consulta de tarjetas.
3. **Cobertura:** `suggestion_test.rb` sólo prueba títulos.
   `SuggestionsControllerTest/comment includes all history and creates no comment`
   comprueba el contexto inicial; los casos de permisos de ese controlador sólo
   autorizan la tarjeta actual. Ninguno comprueba una segunda tarjeta elegida por
   el modelo. Los nuevos casos cubren transporte de herramientas, enlaces HTML,
   menciones por número, exclusión de tarjetas no citadas o no accesibles,
   ausencia de lectura opcional, límites de contexto y repetición.
4. **Seam:** la entrada sigue siendo `Card::Suggestion#comment`, consumida por
   `SuggestionRequest#generate`. La herramienta la ejecuta RubyLLM en producción.
   No se agrega una API de pruebas ni se retira una prueba existente.

## Evidencia

Base de `fizzy-custom`: `6e8cb09ebd4e8e72cc3b758697742512e585bd17`.
La versión final de `suggestion_references_test.rb` tiene SHA-256
`65ad7de9f8b28a2362db2afa6b1f7b550a71aa174c56b35f669361cb522339fd`.

Se exportó esa base con `git archive HEAD` a
`/tmp/handy-1797-base.1S6HoL`, sin usar otro checkout ni otra base de tarjeta.
Se copió sólo la prueba candidata y se preparó SQLite con `RAILS_ENV=test
bin/rails db:prepare`. Ruby: mise 4.0.9. Los comandos se ejecutaron sin las
variables heredadas de Ruby/Bundler:

```sh
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u RUBYLIB -u BUNDLE_GEMFILE \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=2 CI_PROGRESS_BAR=false \
  /home/hermes/.local/share/mise/installs/ruby/4.0.9/bin/ruby \
  bin/rails test test/models/card/suggestion_references_test.rb
```

**RED histórico:** desde la exportación, salida 1: 9 casos, 32 aserciones,
2 fallos y 4 errores. Faltan `tools` y `referenced_cards`, no llega el título
de la tarjeta consultada, no se rechaza su historial grande y el bucle llega
a la séptima petición. La prueba corta el proveedor controlado después de
seis peticiones para que un código sin límite no deje un proceso infinito.
Los negativos que ya devolvían «herramienta desconocida» en la base no se
presentan como evidencia RED de permisos; el caso positivo comprueba que ahora
se ejecuta la herramienta real y los negativos comprueban su rechazo.

**GREEN histórico pareado:** el mismo comando anterior, desde `fizzy-custom/`
con la corrección: salida 0, 9 casos, 51 aserciones, sin fallos ni errores.

**GREEN enfocado:** `test/models/card/suggestion_references_test.rb`,
`test/models/card/suggestion_test.rb` y
`test/controllers/cards/suggestions_controller_test.rb`: 31 casos,
300 aserciones, sin fallos ni errores. Además se agregó un enlace `mailto:`
al caso de lectura: en la implementación inicial falló con
`NoMethodError: undefined method 'match' for nil`. Se excluyeron los esquemas
ajenos a HTTP y el mismo caso pasó. Los enlaces de correo no son referencias.

**Proveedor real:** una prueba sin base de datos, con contenido sintético y
RubyLLM 2.0/Kimi K3 Fast, ofreció `read_referenced_card` con selección `auto`.
El modelo eligió consultarla y respondió con `CIRUELA-1797`, dato presente sólo
en el resultado de la herramienta. Terminó en dos peticiones HTTP. No se envió
contenido de tarjetas reales ni se imprimió la credencial administrada.

**Estilo:** RuboCop sobre los cuatro archivos Ruby del lote y
`script/check_agents_docs`: sin errores.

**Suite OSS final:** desde `fizzy-custom/`, mismo entorno sin variables
heredadas, `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=4
CI_PROGRESS_BAR=false mise exec -- bin/rails test`: salida 0, 3.025 casos,
16.518 aserciones, cero fallos, cero errores y seis omisiones de la suite.

## Límites de la comprobación

Las pruebas HTTP controladas comprueban el transporte y la selección de filas;
no miden la calidad editorial de las propuestas reales. La muestra del proveedor
comprueba compatibilidad y una decisión de consulta, no su frecuencia ni sus
percentiles de tiempo. No hay cambios de interfaz ni prueba visual nueva.
La propuesta no se invalida si una tarjeta consultada cambia después: conserva
el comportamiento de revisión de la tarjeta actual.
