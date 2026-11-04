# Handy 1862: habilitación del envío de comentarios

## Autoría antes de editar las pruebas

- **Contrato:** el formulario de comentarios permite enviar contenido pegado,
  insertado sin teclas o escrito. Al vaciar el campo vuelve a bloquear el envío.
  La edición permite guardar contenido pegado. Los dueños son el controlador
  `form`, los formularios de comentarios y Lexxy. La frontera es el navegador
  con el editor y el formulario reales, incluida la persistencia por Turbo.
- **Regresión:** comprobar `form.checkValidity()` antes de que Lexxy actualice
  `ElementInternals` deja el botón con el estado anterior tras una sola edición.
  Se comprueba también el paso contrario: de contenido a vacío.
- **Cobertura:** `markdown_paste_test.rb` comprueba formato, sin comprobar el
  botón. `ai_suggestion_test.rb` comprueba aceptar una propuesta con un evento
  adicional explícito; no cubre una única inserción por pegado o dictado.
  Los nuevos casos observan esos caminos y la edición de un comentario.
- **Seam:** no se añade API productiva. El pegado usa `ClipboardEvent` con
  `DataTransfer` sobre el editable real, como las pruebas de Markdown. La
  inserción sin teclas usa CDP `Input.insertText`, que modifica el editor por
  el navegador. No sustituye Lexxy, Stimulus ni la validación. CDP no prueba
  el micrófono ni el servicio de dictado nativo de macOS.

## Reproducción previa

Base de `fizzy-custom`: `cd52bfca1934cf43ef3056de2ae1924d2322028c`.
Ruby 4.0.9, Lexxy 1.0.1, SQLite, modo OSS y Chromium en Linux.
Se abrió la tarjeta fixture `layout` con David en el servidor de prueba local,
mediante `bin/agent-browser`. Un pegado único en el editor vacío produjo:

| Momento | Contenido | Validez | Botón deshabilitado |
|---|---|---|---|
| `lexxy:change` | `<p>Comentario pegado de prueba</p>` | false | true |
| Primer frame | igual | false | true |
| Segundo frame | igual | true | true |

Lexxy emite `lexxy:change` desde `#setInternalFormValue` y después registra
`#requestValidityRefresh`, que espera un frame. El listener de `form` registra
su espera antes y lee la validez anterior. El evento sí llega; no falta un
listener de teclado o portapapeles. La edición ya mantiene Guardar activo y
se conserva ese comportamiento.

La tarjeta pide trabajar con un solo agente. No se encargaron auditorías
independientes de investigación; la medición anterior no se presenta como
convergencia ni como refutación independiente. La revisión final corresponde
a los gates de Dédalo y del repositorio.

## Evidencia RED y GREEN

Prueba candidata: `test/system/comment_input_test.rb`, SHA-256
`d143d58b56bb684f860c0c710ff690fb9f41797651fbd14509cd90e133d967b7`.
La base se exportó con `git archive cd52bfca1934cf43ef3056de2ae1924d2322028c`
en `.context/comment-input-base/`. Se copió sólo la prueba candidata y se
preparó su propia base SQLite con `RAILS_ENV=test bin/rails db:prepare`.
No se modificó otra tarjeta, el checkout fuente ni la gema compartida.

Comando exacto, desde la exportación para RED y `fizzy-custom/` para GREEN:

```sh
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- env PATH="/home/hermes/.local/share/mise/installs/ruby/4.0.9/bin:$PATH" \
  ruby bin/rails test test/system/comment_input_test.rb --seed 1862
```

Se antepone el Ruby de mise también para los procesos hijos: este shell sitúa
`/usr/bin` antes de ese Ruby. No basta con seleccionar Ruby en el proceso padre.

- **RED histórico:** salida 1, 4 casos, 19 aserciones, 2 fallos, sin errores.
  Fallan las aserciones de botón activo tras una sola tecla y tras
  `Input.insertText`. El contenido sí se inserta. El pegado pasa en esta
  ejecución; en la reproducción manual y una ejecución anterior sobre la misma
  base quedó bloqueado. El defecto depende del orden de los frames.
- **GREEN:** salida 0, 4 casos, 21 aserciones, sin fallos, errores ni omisiones.
  También se comprueba el envío persistido, el guardado de una edición y el
  bloqueo al borrar. El caso de edición es cobertura de compatibilidad:
  ya pasaba en la base y no se presenta como RED.

Los logs locales son `.context/comment-input-red-final.log` y
`.context/comment-input-green.log`. La evidencia resumida aquí permanece en git.

Se repitió la reproducción manual con `bin/agent-browser` sobre la corrección:
el segundo frame ya mostraba validez `true` y botón deshabilitado `false`.
Borrar con Ctrl+A y Backspace dejó `<p><br></p>` y botón deshabilitado `true`;
`keyboard inserttext` lo volvió a habilitar sin eventos de teclado.

## Validación del repositorio

La suite SQLite (`ruby bin/rails test`, mismo entorno, `PARALLEL_WORKERS=4`)
pasó: 3.025 casos, 16.518 aserciones, 6 omisiones, sin fallos ni errores.
Para sistema se usó el mismo prefijo, con `PARALLEL_WORKERS=1`, y
`ruby bin/rails test:system --seed <seed>`. Se conservan también las ejecuciones
fallidas, sin retirar ni omitir pruebas:

| Código y conjunto de pruebas | Seed | Resultado |
|---|---|---|
| Corrección, suite completa | 47288 | 101 casos, 639 aserciones, 2 fallos y 1 error |
| Corrección, repetición por esos fallos | 47288 | 101 casos, 642 aserciones, 1 fallo y 1 error |
| Base, sin la prueba candidata | 47288 | 97 casos, 623 aserciones, 1 fallo |
| Base, con la prueba candidata | 47288 | 101 casos, 651 aserciones, sin fallos ni errores |
| Corrección, ejecución final | 1862 | 101 casos, 641 aserciones, 2 fallos, sin errores |

El fallo de navegación en `card_stage_navigation_test.rb:21` espera el título
`Done card refreshed` y recibe `The logo isn't big enough`. También ocurre en
la base. El error de caché es un `ScriptTimeoutError` en
`private_offline_cache_test.rb:139`. La primera ejecución también falló en el
ingreso con passkey (`private_offline_cache_test.rb:128`). La clase de caché
pasó por separado en la base: 7 casos, 40 aserciones. No se estableció la causa
del error de caché ni su relación con el orden de ejecución. No se lo presenta
como un defecto comprobado de este cambio ni como un defecto previo comprobado.

La prueba candidata también pasa en una ejecución completa de la base: el RED
enfocado y la traza manual demuestran el defecto, pero no que cada ejecución
de la prueba deba fallar. El orden de los frames puede ocultarlo.

En la ejecución final fallaron navegación y passkey, mientras que el caso de
actualización del worker pasó. No se ha comprobado la causa de la variación de
passkey. La suite de sistema completa no está verde; los cuatro casos nuevos
de comentarios pasan en las tres ejecuciones completas sobre la corrección.
Rubocop del archivo nuevo, `script/check_agents_docs` y `git diff --check` pasan.

## Límites

No se dispone de macOS en este entorno. La inserción sin teclas y el pegado
se comprueban en Chromium; el dictado real de macOS queda sin verificar.
