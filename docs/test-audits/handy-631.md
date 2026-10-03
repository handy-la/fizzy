# Handy 631: aviso de espera en el comentario

## Autoría antes de editar las pruebas

- **Contrato:** mientras se genera la sugerencia, el comentario vacío muestra
  «Preparando sugerencia…» dentro del editor, sin otra línea visible. El valor
  sigue vacío y el botón de publicación sigue deshabilitado. Al terminar,
  fallar, omitir, escribir o desconectar el formulario, termina el aviso de
  espera. Dueño: `ai_suggestion_controller.js`. Frontera: editor Lexxy real.
- **Regresión:** conservar el aviso sólo en el elemento de estado deja el
  placeholder original. No restaurarlo deja la espera después de terminar.
- **Cobertura:** se amplía `comment stays a placeholder until Enter accepts it
  without posting`, el caso táctil y el caso de Cable del archivo
  `test/system/ai_suggestion_test.rb`. Antes comprobaban la propuesta o la línea
  de estado, pero no la espera dentro del campo. Un caso adicional comprueba
  restauración por fallo, respuesta 204, edición y desconexión.
- **Seam:** no se agrega una API productiva. El control de `fetch` existente
  aplaza la respuesta externa; las aserciones observan el editor real, su
  placeholder y el botón. El caso de Cable conserva el transporte real y el
  proveedor simulado existente.

## Evidencia

Base del repo `fizzy-custom`:
`73f4f7caebfff69cf9f9874267eeb06914f3c32b` (`origin/main`).
Ruby 3.4.8 de mise, SQLite y Chromium. Se aplicaron primero sólo las pruebas
candidatas; el controlador seguía idéntico al SHA base.

Desde `fizzy-custom/`, el comando exacto fue:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT -u RUBYLIB -u RBENV_VERSION -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec -- bin/rails test test/system/ai_suggestion_test.rb -n '/comment stays|comment waiting|touch tap|Cable delivers/'
```

- **RED:** salida 1; 4 casos, 14 aserciones, 4 fallos, sin errores.
  Los cuatro fallos indican que no se encuentra el editor con
  `placeholder="Preparando sugerencia…"`. Una primera ejecución se detuvo por
  un puerto ocupado; no cuenta como RED. La repetición obtuvo los fallos del
  contrato. Salida local: `.context/handy-631-red.log` del workspace.
- **GREEN:** mismo comando y pruebas con el cambio: salida 0; 4 casos,
  55 aserciones, sin fallos ni errores. Salida local:
  `.context/handy-631-green-focused.log`.
- **Archivo completo:** mismo entorno y comando sin `-n`: salida 0;
  14 casos, 123 aserciones, sin fallos ni errores.
- **Suite general:** mismo entorno, `PARALLEL_WORKERS=4` y
  `mise exec -- bin/rails test`: salida 0; 1.762 casos, 6.834 aserciones,
  sin fallos ni errores, 6 omisiones.
- **Suite de interfaz:** mismo entorno, `PARALLEL_WORKERS=1` y
  `mise exec -- bin/rails test:system`: salida 0; 40 casos, 246 aserciones,
  sin fallos, errores ni omisiones.
- **Navegador:** captura antes de editar el controlador y captura después,
  con el mismo usuario de desarrollo, tarjeta, tema y tamaño de 1200 × 900.
  Respuesta externa aplazada mediante el mismo control de `fetch`. Enter
  insertó la propuesta, restauró el placeholder original y habilitó el botón
  de publicación. Ambas imágenes están adjuntas a la tarjeta.

## No verificado

No se probó con un proveedor de IA en vivo, con un teléfono físico, ni con
Safari o Firefox. Se conservan las pruebas del transporte Cable y del toque
táctil de WebDriver.
