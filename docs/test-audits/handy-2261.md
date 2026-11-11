# El producto en la franja fija de la tarjeta

## Cambio

Al bajar por una tarjeta aparece una franja fija con su título
(`card-title-bar`). En el Fizzy de Dédalo cada producto tiene su tablero, así
que la franja ahora muestra también el nombre del tablero, en una línea pequeña
en mayúsculas sobre el título. Cada línea corta su texto con puntos
suspensivos; la franja sigue oculta por `[hidden]`, que tiene `!important`
frente a su nuevo `display: flex`.

## Autoría antes de editar pruebas

Base: `a5ad3add1f3600f02b2b0bf88c3deb132cd4e572`.

- **Contrato:** con la franja visible, `.card-title-bar__board` muestra el
  nombre del tablero de la tarjeta (sin distinguir mayúsculas, por el
  `text-transform`) y `.card-title-bar__title` el título; las dos líneas tienen
  altura y no pasan del borde derecho, a 1280 y a 390 píxeles. Dueño:
  `app/views/cards/_container.html.erb` y `card-title-bar.css`. Frontera: DOM.
- **Regresión:** quitar el nombre del tablero de la franja, mostrar otro
  nombre, u ocultar o desbordar una de las dos líneas en el celular.
- **Cobertura:** `test/system/card_title_bar_test.rb` sólo comprobaba el
  título. Se amplía su ayudante `assert_title_bar`, que ya usan los cuatro
  casos (dos tamaños, refresco por broadcast y guardado del título).
- **Seam:** ninguno. Las clases nuevas son marcado productivo.

## Evidencia RED y GREEN

Directorio `fizzy-custom/`, Ruby 4.0.9 de mise antes de `/usr/bin` en `PATH`,
sin `GEM_HOME`, `GEM_PATH` ni `BUNDLE_*` heredados:

```bash
PARALLEL_WORKERS=1 bin/rails test test/system/card_title_bar_test.rb
```

- **RED** (prueba final, vista y CSS de la base): salida 1; 4 casos,
  4 fallos `expected to find css ".card-title-bar__title" but there were no
  matches`.
- **GREEN** (con el cambio): salida 0; 4 casos, 105 aserciones.
- `test/system/card_latest_message_test.rb` mide la altura de la franja para
  dejar visible el último mensaje; sigue en verde con la franja de dos líneas.

No se verificó: cómo se ve con un lector de derecha a izquierda; cada línea
conserva `dir="auto"`.
