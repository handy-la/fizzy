# Alineación del zócalo de salud

## Autoría previa

- **Contrato.** El tablero mantiene el inicio del título, del contador plegado y de
  la primera tarjeta al agregar o actualizar un zócalo. El título plegado sigue
  operativo en una ventana baja y la última tarjeta se puede abrir en móvil.
  El dueño es la vista del tablero de Fizzy. La frontera es el navegador con
  columnas ordinarias, tarjetas persistidas y actualizaciones reales por Cable.
- **Regresión.** Anular el margen o la traslación nativos desplaza el título,
  el contador o las tarjetas frente a una columna humana equivalente. Un pie
  superpuesto intercepta el toque en el título o tapa la última tarjeta.
- **Cobertura.** Se amplía `TickHealthsTest`. El caso abierto comparaba una
  columna consigo misma y medía un marco sin caja. Los casos de Cable e iconos
  verifican contenido, y el caso plegado prueba el pie con teclado y toque en
  una ventana normal. Se conserva esa cobertura y se añade la comparación
  entre columnas, la ventana baja y el desplazamiento de la lista en móvil.
- **Seam.** Ninguno. Se usan la ruta, el contador, las tarjetas, el botón de
  expansión y el indicador de producción. Se mide la caja de una tarjeta
  renderizada. La escritura y las notificaciones usan el mismo camino que
  las pruebas actuales.

## RED y GREEN

Base histórica: `551750e963a0e9507741edd48c8ffd8c70f31b65`. La exportación
`.context/fizzy-red` sólo recibió la candidata
`test/system/tick_healths_test.rb` (blob
`79225ec5ad492e421309b46093e2e40f2dea15f9`) y su base SQLite de prueba.
Se ejecutó el mismo comando en ambas raíces (exportación y `fizzy-custom`):

```bash
# fizzy_ruby es la ruta que devuelve mise which ruby en fizzy-custom.
export PATH="${fizzy_ruby%/*}:$PATH"
unset GEM_HOME GEM_PATH RUBYOPT RUBYLIB BUNDLE_BIN_PATH BUNDLE_PATH
export SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false
ruby bin/rails test test/system/tick_healths_test.rb -i '/columns aligned|long title operable|last card above/'
```

- **RED**, salida 1: siete pruebas, 31 aserciones, siete fallos y cero
  errores. Diferencias de 40 px en el contador plegado de escritorio,
  5,98 px en el título abierto de escritorio y 5,05 px en el contador
  plegado y el título abierto de móvil. El área del expansor invadía el
  zócalo en ambas ventanas bajas. Con un área segura inferior de 24 px
  emulada, el zócalo quedaba 24 px bajo el borde superior de la navegación.
- **GREEN**, salida 0: siete pruebas, 98 aserciones, cero fallos y errores.
  Se compara el inicio de la primera tarjeta cuando la columna está abierta.
  Fizzy oculta las tarjetas al plegar, donde se comparan título y contador.
  El caso móvil desplaza la lista y abre el enlace real de la última tarjeta.
- **Sistema de salud**, mismo entorno y archivo, sin filtro: 13 pruebas,
  227 aserciones, cero fallos y errores. Incluye Cable, iconos, cuenta
  regresiva, detalle y apertura con teclado y toque.

Ruby 4.0.9 y Chromium 152. Los logs están en
`.context/fizzy-tick-{red,green,system}.log` del workspace. Las capturas
antes y después usan el mismo tablero local, con datos de ejemplo, en
1440 × 900 (claro y oscuro) y 390 × 844 (móvil). No se comprobó un dispositivo
físico ni se usaron datos o procesos de producción.
