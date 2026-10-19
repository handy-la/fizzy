# Handy 1265: abrir la tarjeta en su último mensaje

## Autoría antes de editar las pruebas

- **Contrato:** al abrir una tarjeta, la vista queda en el inicio de su último
  mensaje visible, 16 px debajo de la franja fija del título (Handy #1217). Usa
  la misma búsqueda del último mensaje que el botón «Go to the last comment». Vale para una carga
  directa y para una visita Turbo desde el tablero. Un enlace a un mensaje
  (`#comment_…`) conserva ese mensaje. Volver por el historial conserva la
  posición anterior. Una tarjeta sin mensajes visibles queda arriba. Dueños:
  `latest_message_controller.js`, `helpers/comment_helpers.js` y
  `MessagesHelper#messages_tag`; la frontera es el navegador real.
- **Regresión:** quitar el controlador, desplazar sólo en `connect` (una
  visita Turbo vuelve arriba después de renderizar), no dejar lugar para la
  franja, ignorar el ancla o desplazar en una visita `restore` hace fallar un
  caso.
- **Cobertura:** `CardDockSystemTest` prueba el salto con el botón, no la
  apertura. `CardTitleBarTest` y `CardRefreshTest` abren la tarjeta, pero no
  comprueban la posición inicial. Ninguna prueba cubre ancla ni historial.
  Los dos tamaños de ventana protegen la misma frontera con otro layout.
- **Seam:** ninguno. La búsqueda del último mensaje se movió del controlador
  de la barra a `helpers/comment_helpers.js`; sus consumidores son la barra y
  el controlador nuevo, ambos productivos.

`CardDockSystemTest` y el caso de tamaños de `CardTitleBarTest` suponían que la
tarjeta abre arriba. Ahora vuelven arriba con `window.scrollTo(0, 0)` después
de abrir, porque prueban lo que pasa al bajar desde arriba. Sus aserciones no
cambian.

## Evidencia

Base sin la mejora: `b8cc9d4b2616f8994d94ea313df1208ec82de3e1`. Desde
`fizzy-custom/`, Ruby de mise, con sólo
`test/system/card_latest_message_test.rb` agregado:

```sh
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT \
  -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/system/card_latest_message_test.rb
```

RED: salida 1. Los dos tamaños, la apertura desde el tablero y la condición
previa del caso de historial fallaron por el contrato: el último mensaje
empezaba a 3158,8 px (1280 px de ancho) o 2861,5 px (390 px) del borde, en
lugar de 16 px. Los casos de ancla y de tarjeta sin mensajes pasaron: son
guardas de lo que el cambio no debe romper. La primera versión del caso del
tablero no encontró el enlace porque la columna de la tarjeta estaba plegada;
la prueba manda la tarjeta a *Maybe?*, la columna abierta.

La primera implementación dejaba 16 px desde el borde, como el botón de la
barra. La captura manual mostró que la franja del título tapaba el autor y la
hora del mensaje. Las pruebas ahora miden desde el borde inferior de la franja;
con esa implementación fallaban. El controlador mide la franja oculta en la
misma tarea, sin pintar. El botón de la barra no cambia: queda fuera del
alcance de esta tarjeta.

El caso del historial falló 1 de 6 veces con `scrollY` = 45. La traza de
eventos mostró que lo restaura Turbo: el tablero se desplaza tarde y Turbo
guarda esa posición para la tarjeta; el controlador no se mueve. El caso
comprueba que el encabezado de la tarjeta sigue visible. Al quitar la guarda
de `restore`, ese caso falla.

GREEN con el mismo comando y el cambio: salida 0; 6 casos, 0 fallos, 8 de 8
corridas seguidas.

No se comprobó Safari ni un dispositivo físico; las pruebas usan Chromium.
Una imagen que termina de cargar después del salto puede mover el mensaje;
Chromium y Firefox anclan el desplazamiento al contenido visible.
