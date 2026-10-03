# Siguiente tarjeta en todas las etapas: Handy 628

## Autoría antes del cambio

- **Contrato:** al cambiar de etapa o marcar Done desde la página de una
  tarjeta, se ofrece otra tarjeta de la etapa de origen. El enlace usa la
  cuenta y el tablero actuales. La tarjeta que acaba de moverse queda
  excluida. Sin tarjetas pendientes, se indica que la etapa está vacía.
  El aviso debe sobrevivir a una actualización automática de la tarjeta
  hasta pulsar Continue o Dismiss, sin pasar a la siguiente tarjeta.
  Undo elimina el aviso de Done porque esa acción ya se revirtió.
  Dueños: controladores de triage, cierre y aplazamiento, vista de tarjeta
  y controlador Stimulus de conservación del aviso.
  Fronteras: respuestas HTML/Turbo Stream y navegador real.
- **Regresión:** conservar el filtro AWAITING APPROVAL, exigir movimiento
  hacia la derecha o no enviar el aviso en la respuesta de Done hace fallar
  los casos de navegación. Una fuente incorrecta recomienda la tarjeta
  cerrada o una tarjeta de otra etapa.
  El refresco de Cable puede eliminar un aviso enviado por Turbo Stream.
  Reutilizar el mismo id permanente al mover otra vez la tarjeta conserva
  el aviso de la etapa anterior. El caso de selector seguido de dock debe
  comprobar el nuevo origen sin cerrar el primer aviso.
- **Cobertura:** se amplía `test/integration/card_dock_test.rb`, que antes
  cubría sólo la aprobación hacia delante. Sus negativos para retroceso y
  selector cambian porque la tarjeta pide esos flujos. Los controladores
  existentes comprueban la mutación y el contenedor, pero no el aviso.
  Una prueba de sistema comprueba la inserción real de Turbo Stream,
  Continue, Dismiss, Undo y el selector dentro de un frame. Esa frontera no se
  demuestra sólo con HTML de integración.
- **Seam:** peticiones, botones y enlaces productivos. No se agrega una API
  exclusiva para pruebas. Los datos se preparan con fixtures y operaciones
  reales del modelo.

## RED histórico y GREEN

Base sin el cambio: `7162548c0c92de9e5a498bb17b3acce525c8cbbc`.
Se exportó `origin/main` con `git archive` a
`.context/handy-628-base` y se copiaron sólo las dos candidatas finales.
No se usó otro worktree ni el source checkout.

SHA-256 de las candidatas:

- `test/integration/card_dock_test.rb`:
  `5942a05fdcaeeb3dfcb29ff6dfdf0090e64f8a2827baa656db6083eb33f8443f`.
- `test/system/card_stage_navigation_test.rb`:
  `871565da76b134f953fb9454e1121b4b9ec3ae0b0dd8e6bbd7965c8ab327eda9`.

Todos los comandos Rails usan Ruby 3.4.8 de mise, SQLite y el bundle OSS.
Desde `fizzy-custom/`, el comando RED exacto fue:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ruby -e 'Dir.chdir("../.context/handy-628-base"); exec("./bin/rails", "test", "test/integration/card_dock_test.rb", "test/system/card_stage_navigation_test.rb")'
```

RED: salida 1; 18 casos, 88 aserciones, 9 fallos y ningún error.
Faltaban el enlace en columnas distintas de aprobación, los avisos de Done
y de las etapas especiales, y el aviso en retroceso y selector. Los dos
casos de navegador fallaron por ausencia de `.approval-toast` después de
la acción real. Log local: `handy-628-final-red.log`.

GREEN: el mismo entorno, en `fizzy-custom/`, con
`mise exec -- bin/rails test test/integration/card_dock_test.rb
test/system/card_stage_navigation_test.rb`: salida 0; 18 casos,
133 aserciones, sin fallos ni errores. Log local: `handy-628-final-green.log`.

La versión intermedia mostraba el aviso, pero un refresco real de Cable lo
eliminaba. La prueba de sistema se amplió antes de proteger el aviso:
`bin/rails test test/system/card_stage_navigation_test.rb` dio salida 1,
2 casos y 12 aserciones; después de comprobar el nuevo título del refresco,
no encontró `.approval-toast`. Log: `handy-628-refresh-red.log`.
Ese resultado demuestra el fallo de ciclo de vida en la versión intermedia;
el RED histórico anterior sigue siendo la evidencia contra la base.

Una segunda prueba sobre la versión intermedia movió la tarjeta otra vez
sin cerrar el aviso. Falló con salida 1, un caso y cinco aserciones: debía
mostrar «The text is too small», pero conservó «Layout is broken» de Triage.
Log: `handy-628-repeated-move-red.log`. La solución final conserva sólo el
contenedor vacío durante un morph del mismo id; un nuevo aviso sustituye al
anterior. No usa `data-turbo-permanent`.

## Validación final

| Comando con el entorno anterior | Resultado |
|---|---|
| `PARALLEL_WORKERS=4 mise exec -- bin/rails test` | Salida 0; 1.770 casos, 6.897 aserciones, 6 omisiones |
| `PARALLEL_WORKERS=1 mise exec -- bin/rails test:system --seed 53601` | Salida 0; 40 casos, 233 aserciones, sin omisiones |
| Casos de integración más controladores de triage, cierre y Not now | Salida 0; 26 casos, 183 aserciones |
| RuboCop sobre los siete archivos Ruby modificados | Salida 0; sin infracciones |
| `git diff --check` | Salida 0 |

Log local de ambas suites finales: `handy-628-suites-final.log`. Las primeras ejecuciones de sistema
fallaron porque la prueba móvil dejaba la ventana en 390 × 844. La base
exportada pasó sus 38 casos. Se corrigió el aislamiento de la prueba con
`ensure`; no se cambió ni retiró una prueba de navegación o notificaciones.

QA manual con `bin/agent-browser`: selector To work → WIP, Done en WIP,
Continue a la otra tarjeta, y cierre del aviso. Las capturas antes se
tomaron desde la exportación sin el cambio, en el mismo puerto, con una
copia aislada de los datos QA. Las cuatro capturas usan el mismo usuario,
tema claro y ventana de 1280 × 900; se adjuntan a la tarjeta.

No se retiraron pruebas ni APIs. Los dos negativos anteriores de
`CardDockTest` se convierten en positivos porque retroceso y selector son
parte del nuevo contrato. Se conserva el negativo para movimiento en la
misma etapa y se agrega el negativo de JSON sin aviso pendiente.

## Lo que no se verificó

No se probó una instalación SaaS, un cliente nativo ni un despliegue en
producción. Se validó la aplicación OSS local. Las seis omisiones de la
suite Rails permanecen declaradas por el runner; no se desactivó ninguna
prueba para esta entrega.
