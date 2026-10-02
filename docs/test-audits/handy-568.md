# Handy 568: pegado Markdown en Chromium

## Autoría antes de editar las pruebas

- **Contrato:** `markdown paste adds block spacing` comprueba que el pegado
  añade espacio entre párrafos. `markdown paste preserves line breaks`
  comprueba que un salto simple se conserva como `<br>`. El dueño es Lexxy
  0.9.32 y, para el espacio entre bloques, el listener de Fizzy en
  `app/javascript/initializers/lexxy_markdown_paste.js`. La frontera es un
  evento de portapapeles en el campo editable real, con aserciones sobre el DOM.
- **Regresión:** quitar `event.detail.addBlockSpacing()` debe romper el primer
  caso. Perder el `<br>` o fusionar las líneas debe romper el segundo. El clic
  de preparación debe llegar al campo aunque esté visible la barra flotante.
- **Cobertura:** se corrigen estos dos casos existentes. Las pruebas de
  `ai_suggestion_test.rb` usan el mismo editor, pero no comprueban el formato
  del pegado Markdown. No se añade otra capa ni se retira cobertura.
- **Seam:** se conserva el evento DOM `paste` del navegador. No se cambia la
  API productiva. El helper privado prepara `DataTransfer` porque Selenium
  no expone el contenido del portapapeles del sistema de forma portátil.
  La prueba continúa por Lexical, Lexxy y el listener real de Fizzy.

## Investigación

Base: `e6f95af120ca3b82fe60700b58494d3e8ec561db` de `fizzy-custom`.
Ruby 3.4.8; Chromium y ChromeDriver 152.0.7977.82; SQLite; `SAAS=false`.

La ejecución original con seed 39952 pasó: 2 casos, 6 aserciones.
Un diagnóstico temporal repitió cada caso 16 veces, con el mismo setup y
teardown. Antes del pegado registró el foco, la selección, el rectángulo del
editor y el elemento situado en su centro. Resultado: 32 casos, 95 aserciones,
1 error, salida 1, por ausencia de `Hello` en `preserves line breaks`.

En el caso fallido, `document.activeElement` era `BODY`, la selección estaba
en `Mark as Done` y el centro del editor estaba cubierto por
`.card-dock__done`. En los casos correctos, el foco estaba en
`#comment_body-content`. La captura automática confirmó la superposición.
La prueba hacía clic en el centro de `lexxy-editor` y enviaba el pegado al
foco global, sin comprobar que el campo tuviera el foco.

La hipótesis inicial de un clic sobre la barra de herramientas no se confirmó.
La medición identifica la barra flotante de la tarjeta como causa del fallo
capturado. No se ha hecho una auditoría independiente de investigación: esta
tarjeta exige trabajar con un solo agente. La revisión final queda a cargo de
los gates. El hallazgo aún no tiene una refutación independiente.

## Excepción RED para una reparación de pruebas

No se modifica código productivo. Aplicar las pruebas corregidas a esta base
debe dar GREEN: cambia la preparación de la prueba, no el comportamiento del
editor. Por eso no se presenta esa ejecución como RED histórico de una
regresión productiva. El RED es el error medido en las pruebas originales,
con la superposición y el foco incorrecto registrados arriba.

La validación alternativa debe repetir ambos casos corregidos y comprobar
sensibilidad del caso de espacio entre bloques al retirar temporalmente el
listener, en una exportación aislada. El riesgo sin comprobar es el pegado
nativo mediante el portapapeles del sistema operativo.

## Validación y límites

El cambio desplaza el campo editable al centro de la ventana, hace clic cerca
de su esquina superior izquierda, comprueba `:focus` y envía el evento al nodo
encontrado. `cancelable: true` permite al editor cancelar el evento como en un
pegado normal. Las aserciones de formato permanecen iguales.

Todos los comandos de Rails usan este prefijo, desde `fizzy-custom/` o desde
la raíz de la exportación aislada según la tabla:

```sh
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false mise exec --
```

| Ejecución | Comando después del prefijo | Resultado |
|---|---|---|
| Original, base sin cambios | `bin/rails test test/system/markdown_paste_test.rb --seed 39952` | 2 casos, 6 aserciones, salida 0 |
| Diagnóstico original | `ruby -Itest ../.context/markdown_probe.rb --seed 39952` | 32 casos, 95 aserciones, 1 error por ausencia de `Hello`, salida 1 |
| Prueba corregida | `bin/rails test test/system/markdown_paste_test.rb --seed 39952` | 2 casos, 8 aserciones, salida 0 |
| Repetición corregida | Comando Ruby de abajo, seed 39952 | 64 casos, 256 aserciones, salida 0 |
| Exportación de la base con la prueba corregida y sin `addBlockSpacing()` | `bin/rails test test/system/markdown_paste_test.rb --seed 39952` | 2 casos, 7 aserciones, 1 fallo por ausencia de `p br`, salida 1; saltos simples pasan |
| Misma exportación con el listener restaurado | Mismo comando | 2 casos, 8 aserciones, salida 0 |
| Suite SQLite | `bin/rails test` | 1.757 casos, 6.786 aserciones, 6 omisiones, salida 0 |
| Suite de navegador | `bin/rails test:system` | 31 casos, 159 aserciones, salida 0 |

La exportación se creó con `git archive origin/main` en una carpeta temporal
de este trabajo. Se copió allí la versión corregida de
`test/system/markdown_paste_test.rb`. Sólo en esa copia se sustituyó el listener
por `document.addEventListener("lexxy:insert-markdown", (event) => {})` y después
se restauró. Sus bases SQLite y sus assets son propios. No se modificó la gema
compartida, otra tarjeta ni el checkout fuente.

Comando de repetición, después del prefijo:

```sh
ruby -Itest -r./test/system/markdown_paste_test -e 'originals = MarkdownPasteTest.public_instance_methods(false).grep(/^test_/); 31.times { |i| originals.each { |method| MarkdownPasteTest.define_method("#{method}_repeat_#{i}") { send(method) } } }' -- --seed 39952
```

El diagnóstico original usó 15 repeticiones adicionales en lugar de 31.
Su módulo temporal envolvió el helper original con `page.evaluate_script`
para obtener `document.activeElement.outerHTML`,
`window.getSelection().anchorNode?.parentElement?.outerHTML`,
`editor.getBoundingClientRect()` y `document.elementFromPoint()` en el centro
del rectángulo, y después llamó a `super`. Salida relevante del caso fallido:

```text
test_markdown_paste_preserves_line_breaks_repeat_10
active: BODY
selection: <span class="for-screen-reader">Mark as Done</span>
editor: [218.859375, 392.171875, 785.09375, 265.0625]
center: <div class="card-dock__done">…</div>
Capybara::ElementNotFound: Unable to find visible css "lexxy-editor p" with text "Hello"
```

`bin/rubocop test/system/markdown_paste_test.rb` pasó sin infracciones.
`script/check_agents_docs` y `git diff --check` también pasaron.

Las suites completas usaron seeds 26013 y 18908, respectivamente.
No se verificó el portapapeles
nativo del sistema, otros navegadores ni todas las dimensiones de ventana.
Las repeticiones comprueban Chromium con la ventana usada por esta suite;
no prueban que toda interacción con una barra superpuesta funcione.
