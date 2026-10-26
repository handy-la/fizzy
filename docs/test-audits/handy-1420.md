# El título sugerido nombra la tarea y no contesta la descripción

## Autoría previa a las pruebas

- **Contrato:** `Card::Suggestion#title` envía la descripción al proveedor como
  un campo etiquetado (`{"description": …}` en JSON), no como un mensaje de chat
  suelto. Las instrucciones piden nombrar la tarea de la tarjeta y no contestarla.
  La frontera observada es la petición HTTP a Fireworks.
- **Regresión:** volver a enviar el texto plano como mensaje del usuario. Con
  ese envío el modelo trata la descripción como un pedido y lo contesta.
- **Cobertura:** los casos de `title` en `test/models/card/suggestion_test.rb`
  sólo comprueban la limpieza de la respuesta. Ninguno lee el cuerpo enviado.
  El nuevo caso `title sends the description as a labelled field, not as a
  request to answer` queda en el mismo archivo.
- **Seam:** ninguno. Se usa `title` y WebMock en el límite HTTP de RubyLLM.

La prueba no demuestra la calidad del modelo: sólo fija el formato del envío.
La calidad se midió aparte con el modelo real (sección siguiente).

## Medición con el modelo real

Entrada: la descripción guardada de la tarjeta Handy #1419 (texto plano de la
API de Fizzy). Modelo `accounts/fireworks/routers/kimi-k3-fast`, los mismos
parámetros que `generate` (`reasoning_effort: none`, 2.000 tokens), con la
clave de Fizzy de Dédalo. 60 pedidos por prompt:

| Prompt | Títulos que contestan («Aquí tienes…», «Aquí están…») | Títulos de tarea |
|---|---|---|
| `origin/main` (texto suelto) | 6 | 54 |
| este cambio (JSON + instrucciones) | 0 | 60 |

Con este cambio, 24 de 60 fueron «Actualizar textos del landing page»; el
resto, variantes como «Cambiar textos aprobados en landing page».
Una primera versión con un ejemplo en español respondió en español a una
descripción en inglés (1 de 4); sin el ejemplo, 8 de 8 salieron en inglés.
También se comprobó a mano un reporte de fallo, un pedido de correo y un
texto de inyección: los títulos nombran la tarea.

El resultado es una muestra, no una garantía: el modelo no es determinista.

## Evidencia RED y GREEN

Base del repo Fizzy: `d7e00d424bf451b49f5fa0951a4b5b4e3ea37607`.
Se exportó con `git archive HEAD` en `.context/handy-1420-base` del workspace
y sólo se copió la prueba candidata (SHA-256
`15084cf2cca4a8cfccf6d512e2f2bce02f457a979dc0fbc61fef62e7588fefd9`).

Desde `fizzy-custom/`, Ruby de mise y SQLite:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  -u BUNDLE_BIN_PATH -u BUNDLE_GEMFILE \
  SAAS=false BUNDLE_GEMFILE=Gemfile CI_PROGRESS_BAR=false PARALLEL_WORKERS=1 \
  mise exec -- bash -c \
  'cd ../.context/handy-1420-base && bin/rails test test/models/card/suggestion_test.rb'
```

RED: salida 1; 5 casos, 1 fallo, sin errores. WebMock informa que el mensaje
del usuario fue el texto suelto `Ayúdame a cambiar estos textos en el landing
page:`. Log local: `.context/handy-1420-red.log`.

GREEN: el mismo comando con `bin/rails test
test/models/card/suggestion_test.rb` en `fizzy-custom/`. Salida 0; 5 casos,
11 aserciones. Log local: `.context/handy-1420-green.log`.

`bin/rubocop app/models/card/suggestion.rb test/models/card/suggestion_test.rb
-f simple`: sin infracciones.

Suite completa, mismo entorno con `PARALLEL_WORKERS=2 mise exec -- bin/rails
test`: salida 0; 2.233 casos, 9.710 aserciones, sin fallos ni errores, seis
omisiones. Log local: `.context/handy-1420-suite.log`.

Sin cambio visual: cambia sólo el texto que recibe el modelo.
