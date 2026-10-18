# Handy 1217: título fijo al leer los comentarios

## Autoría antes de editar la prueba

- **Contrato:** la vista privada de una tarjeta oculta la franja mientras la
  tarjeta principal está visible; después muestra su título en una franja fija,
  pegada a los tres bordes superiores de la ventana. Al volver, la oculta.
  La vista, su CSS y Stimulus son los dueños; la frontera es el navegador real.
- **Regresión:** eliminar la franja, observar sólo el encabezado (aparición
  prematura), limitar su ancho al de la tarjeta o perder el título/visibilidad
  durante un refresco remoto debe hacer fallar los casos.
- **Cobertura:** `CardDockSystemTest` verifica botones inferiores desde que sale
  el encabezado. `CardRefreshTest` verifica título y descripción principales.
  Ninguna comprueba el título superior, su umbral, geometría o refresco al bajar.
  Los dos tamaños de ventana protegen la misma frontera con distinto layout.
- **Seam:** ninguno nuevo. Se usan navegación, desplazamiento y actualización
  con broadcast reales. Los selectores CSS son los del componente visible.

## Evidencia

Base sin la mejora: `97396918c70a99f3108dc28ca3de5c7b127f1cf2`.

Con sólo la prueba candidata aplicada, desde `fizzy-custom/`, Ruby 3.4.8:

```sh
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT \
  -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/system/card_title_bar_test.rb
```

RED: salida 1; 3 casos, 14 aserciones, 3 fallos, 0 errores. En los tres casos
no se encontró `.card-title-bar` después de salir la tarjeta principal.
La prueba de escritorio y móvil pasó antes por la ausencia de la franja
cuando sólo había salido el encabezado. No se confundió un error de entorno
con el fallo del contrato.

El caso de edición local comprueba además el título después de guardar en la
misma pantalla. Es una frontera distinta al refresco de Cable: la respuesta
Turbo Stream actualiza el contenedor de la tarjeta sin recargar toda la vista.

La primera implementación dejaba la franja fuera del contenedor actualizado
por Turbo Stream. El comando anterior con `-n /saving/` dio salida 1: un caso,
tres aserciones y un fallo; la franja todavía decía «Layout is broken» después
de guardar «A title saved in this session». La comprobación manual confirmó
lo mismo. La franja quedó dentro del contenedor que ya actualiza el guardado.

También se exportó la base indicada a `../.context/title-bar-base` con
`git archive`, y se copió únicamente la versión final de
`test/system/card_title_bar_test.rb`. Desde `fizzy-custom/`, con el mismo
prefijo `env` del comando anterior:

```sh
# Preparación de las bases SQLite exclusivas de la exportación:
BUNDLE_GEMFILE=../.context/title-bar-base/Gemfile RAILS_ENV=test \
  mise exec -- ruby ../.context/title-bar-base/bin/rails db:prepare
# Prueba candidata completa sobre la base sin implementación:
BUNDLE_GEMFILE=../.context/title-bar-base/Gemfile PARALLEL_WORKERS=1 \
  CI_PROGRESS_BAR=false mise exec -- ruby ../.context/title-bar-base/bin/rails \
  test ../.context/title-bar-base/test/system/card_title_bar_test.rb
```

RED de los cuatro casos definitivos: salida 1; 4 casos, 17 aserciones,
4 fallos, 0 errores y 0 omisiones. Todos fallaron por ausencia de la franja.
GREEN con el comando original en el checkout corregido: salida 0;
4 casos, 47 aserciones, 0 fallos, 0 errores y 0 omisiones.

La comprobación manual usó la misma tarjeta local, usuario y tema en ventanas
1280×800 y 390×844, antes y después. Se verificaron además el regreso arriba,
el tema oscuro y el guardado local del título. Las capturas se adjuntaron a
la tarjeta. Los títulos largos usan puntos suspensivos para mantener compacta
la franja.

No se comprobó Safari ni un dispositivo físico; las pruebas de sistema usan
Chromium real. La mejora sólo afecta la vista privada de tarjetas publicadas.

## Validación de la primera entrega

Con el entorno OSS, Ruby de mise y bases SQLite del propio checkout:

- `bin/rails test`, `PARALLEL_WORKERS=2`: 2186 pruebas, 9398 aserciones,
  0 fallos, 0 errores, 6 omisiones de la suite existente.
- `bin/rails test:system`, `PARALLEL_WORKERS=1`: 87 pruebas, 584 aserciones,
  0 fallos, 0 errores, 0 omisiones.
- `bin/rubocop test/system/card_title_bar_test.rb`: sin infracciones.
- `git diff --check`: sin errores.

## Ajuste pedido: conservar el color del estado

Antes de ampliar las pruebas:

- **Contrato:** la franja tiene el mismo fondo y color de texto que el
  encabezado del tablero en la tarjeta. Debe seguir el estado actual, incluido
  un cambio de columna desde otra sesión y el cierre desde la barra inferior.
- **Regresión:** usar el fondo neutro de la página o fijar un color independiente
  de la tarjeta rompe la correspondencia visible.
- **Cobertura:** los cuatro casos anteriores protegen visibilidad, geometría y
  título, pero no colores. Se amplían los casos de escritorio/móvil y refresco
  remoto de `CardTitleBarTest`, sin duplicar la navegación existente.
- **Seam:** ninguno nuevo. Se comparan estilos calculados de dos elementos
  productivos y se usan el movimiento real de columna y el botón de cierre.

Base anterior al ajuste de color: `c141ae16dc6ae09fa524e8ce377d999daa89f2fe`.


Con sólo la prueba ampliada aplicada sobre esa base, el comando OSS anterior
(`bin/rails test test/system/card_title_bar_test.rb`, mismo entorno y directorio)
dio RED: salida 1; 4 casos, 23 aserciones, 3 fallos y 0 errores. Los tres fallos
comparan el fondo del encabezado con el fondo neutro anterior de la franja.

Después de usar `--card-color` y `--color-ink-inverted` en la franja, el mismo
comando dio GREEN: salida 0; 4 casos, 56 aserciones, 0 fallos, 0 errores y
0 omisiones. El caso remoto verifica además una columna con otro color y el
cierre desde el botón real. La comparación finaliza primero la transición CSS
del encabezado, para comparar el estado final y no un fotograma intermedio.
Se comprobó manualmente la misma correspondencia en tema claro y oscuro.
