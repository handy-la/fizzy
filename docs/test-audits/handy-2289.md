# Número de tarjeta en la franja fija

## Autoría antes de editar pruebas

Base del repo: `0345340c25421ce2dd8cd6488f47709f3159484e`.

- **Contrato:** al bajar en el detalle, la franja muestra el número de la tarjeta abierta junto al producto. El número queda completo y dentro de la pantalla a 1280 y 390 píxeles, incluso con un nombre de producto largo. Dueños: `cards/_container.html.erb` y `card-title-bar.css`. Frontera: DOM visible y geometría del navegador.
- **Regresión:** omitir el número, usar otro número u ocultarlo al recortar un nombre largo.
- **Cobertura:** se amplía `CardTitleBarTest#assert_title_bar`, usado por los casos de scroll, refresco remoto y guardado local. Ya comprueba el producto y el título, pero no el número. Los dos casos de tamaños usarán un producto largo y comprobarán que el número no se recorta.
- **Seam:** ninguno nuevo. Se observa el marcado que ve la persona en el navegador.

## Evidencia

Directorio: `fizzy-custom/`. Ruby 4.0.9 de mise. Comando exacto en ambos estados:

```bash
env -u GEM_HOME -u GEM_PATH -u BUNDLE_PATH -u RUBYOPT -u RUBYLIB \
  PATH=/home/hermes/.local/share/mise/installs/ruby/4.0.9/bin:/usr/local/bin:/usr/bin:/bin \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  ruby bin/rails test test/system/card_title_bar_test.rb
```

- **RED:** misma prueba final (cambio de `card_title_bar_test.rb` de esta tarjeta), aplicada sobre la base indicada, antes de editar vista y CSS. Salida 1; 4 casos, 25 aserciones, 4 fallos: `expected to find css ".card-title-bar__number" but there were no matches`.
- **GREEN:** con vista y CSS nuevos. Salida 0; 4 casos, 154 aserciones, sin fallos ni errores.
- Evidencia de trabajo: `.context/red-card-title-bar.log` y `.context/green-card-title-bar.log` en la raíz del workspace. El resumen anterior conserva la evidencia necesaria aunque se elimine el worktree.
- Suite general: mismo entorno, `PARALLEL_WORKERS=2 ruby bin/rails test`. Salida 0; 3143 casos, 17539 aserciones, 0 fallos, 0 errores y 5 omisiones.
- Suite de navegador: mismo entorno, `PARALLEL_WORKERS=1 ruby bin/rails test:system`. Salida 1; 111 casos, 829 aserciones, 1 fallo, 0 errores. Falla `CardStageNavigationTest#test_Done_from_the_mobile_header_offers_Continue_to_another_source_card`: espera `h1` con `Done card refreshed`, pero mantiene `The logo isn't big enough`.
- Comprobación de la base: exportación aislada de `git archive origin/main` en `.context/fizzy-base/`, SHA base indicado arriba, sin modificaciones. Mismo entorno y `ruby bin/rails test test/system/card_stage_navigation_test.rb`: salida 1; 2 casos, 11 aserciones, el mismo único fallo. Por tanto el fallo existe sin este cambio. No se modifica esa prueba ni su comportamiento.
- Logs adicionales: `.context/suite-fizzy.log`, `.context/system-fizzy.log` y `.context/base-stage-navigation.log` en el workspace.
- RuboCop del archivo modificado: salida 0, sin infracciones.
- Capturas antes y después en 1280 × 800 y 390 × 844: mismo usuario, tarjeta, tema y contenido, con la franja visible; adjuntas a la tarjeta.

No se verificó con un lector de pantalla ni con un navegador distinto de Chrome. La franja conserva su `aria-hidden`, porque repite los datos de la tarjeta, y el número usa dirección izquierda a derecha.
