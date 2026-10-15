# Títulos sugeridos breves y limpios

## Autoría previa a las pruebas

- **Contrato:** `Card::Suggestion#title` devuelve un título editable de hasta
  60 caracteres, sin los signos prohibidos ni emoji, con espacios normales
  y sin cortar palabras. El prompt pide de 3 a 8 palabras en el idioma de
  la descripción. La frontera observada es el método público con una respuesta
  simulada del proveedor HTTP.
- **Regresión:** conservar el recorte de 255 caracteres o quitar la limpieza
  devuelve signos y palabras incompletas. Un recorte por bytes rompe títulos
  con acentos. Las entradas incluyen una respuesta larga con `**`, `/` y `:`;
  otra verifica comillas Unicode, Markdown y secuencias de emoji. Los casos
  de longitud cubren 60 exactos, la palabra siguiente y una palabra de más de 60.
- **Cobertura:** `Cards::SuggestionsControllerTest`, caso `suggest a title
  from the unsaved description without changing the draft`, sólo recibe un
  título corto ya limpio. Los casos de `Card::SuggestionQueueTest` cubren
  admisión y planificación. Ninguno exige el saneado o el límite por palabra.
  Los nuevos casos quedan juntos en `test/models/card/suggestion_test.rb`.
- **Seam:** se usa `title`, llamado por `Card::SuggestionRequest#generate`,
  y WebMock en el límite HTTP de RubyLLM. No se agrega una API de prueba ni
  se sustituye el método que limpia la respuesta.

## Evidencia RED y GREEN

Base del repo Fizzy: `d875b47ca2f485084096e264b501ad550fe4bb13`.
Se exportó con `git archive HEAD` en `.context/handy-1077-base` del workspace.
Sólo se copió la candidata `test/models/card/suggestion_test.rb` a esa
exportación. Su SHA-256, igual en RED y GREEN, es
`91fb659861ef66b20aac0394c9381257ae6237b96a8d2090a7e5b8d27d221d48`.
No se usó otro worktree ni el checkout fuente.

Desde `fizzy-custom/`, con Ruby 3.4.8 y SQLite:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  -u BUNDLE_BIN_PATH -u BUNDLE_GEMFILE \
  SAAS=false BUNDLE_GEMFILE=Gemfile CI_PROGRESS_BAR=false PARALLEL_WORKERS=1 \
  mise exec -- bash -c \
  'cd ../.context/handy-1077-base && bin/rails test test/models/card/suggestion_test.rb'
```

RED: salida 1; 4 casos, 5 aserciones, 4 fallos, sin errores ni omisiones.
El caso largo devolvió `**Corregir** / la : impresión...` con el resto de la
respuesta sin recortar. Los otros fallos conservaron Markdown y emoji,
aceptaron la palabra posterior a los 60 caracteres y aceptaron una palabra
de 61 caracteres. Los fallos son del contrato, no de la preparación.
Log local: `.context/handy-1077-red.log`.

GREEN: mismo entorno y comando de Rails desde `fizzy-custom/`, con
`mise exec -- bin/rails test test/models/card/suggestion_test.rb`.
Salida 0; 4 casos, 10 aserciones, sin fallos, errores ni omisiones.
Log local: `.context/handy-1077-green.log`.

Antes de esta versión de la candidata se corrigió un esperado que tenía
61 caracteres. La versión con ese error no se presenta como evidencia GREEN.

## Alcance de la limpieza

Se conservan letras, marcas Unicode, números y espacios. Se quita la
puntuación para cumplir la instrucción de usar palabras simples sin Markdown.
Los emoji se quitan por grupo completo, incluidos banderas, modificadores,
teclas y secuencias con unión. El recorte exige espacio o fin de texto después
del último carácter: una primera palabra de más de 60 no devuelve un fragmento.
El prompt pide de 3 a 8 palabras; Ruby garantiza la limpieza y el límite de 60,
sin inventar palabras cuando la respuesta no permite ese mínimo.

## Otras comprobaciones y límites

`bin/rubocop app/models/card/suggestion.rb test/models/card/suggestion_test.rb
-f simple`, con el mismo Ruby y entorno OSS: salida 0, sin infracciones.

Suite completa: mismo entorno, `PARALLEL_WORKERS=2 mise exec -- bin/rails test
--seed 43719`. Salida 0; 2.158 casos, 9.303 aserciones, cero fallos y errores,
seis omisiones. Log local: `.context/handy-1077-suite.log`.

La primera ejecución de esa semilla falló en
`My::PasskeyChallengesControllerTest#test_uses_authentication_challenge_expiration_by_default`,
en su aserción de vigencia. No se cambió esa prueba ni su código productivo.
Se ejecutó su archivo por separado con el mismo entorno y un worker:
`bin/rails test test/controllers/my/passkey_challenges_controller_test.rb`.
Salida 0; cinco casos y diez aserciones. La repetición completa de la misma
semilla pasó. No se ha determinado la causa del fallo intermitente.
Logs locales: `.context/handy-1077-suite-passkey-failure.log` y
`.context/handy-1077-passkey-recheck.log`.

No se cambian estilos, vistas ni textos fijos de una pantalla: sin cambio
visual. No se comprueba una llamada real al proveedor, pruebas de navegador
ni el modo SaaS.
