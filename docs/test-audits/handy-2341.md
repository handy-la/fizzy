# Handy 2341: un segundo comentario publicaba otra vez el anterior

## Síntoma reportado

En una tarjeta se publica el comentario A. Sin salir de la tarjeta se escribe
B y se envía. Se publica A otra vez y B se pierde.

## Causa demostrada

Son dos defectos que se combinan. Se midieron en Chrome con pruebas de sistema
y en el servidor de desarrollo (sección «Reproducción en un navegador real»).

1. **El borrador local vuelve a guardar el texto enviado.** `local-save`
   guardaba el editor 300 ms después del último cambio. Al publicar, el
   `turbo:submit-end` exitoso borraba el borrador, pero si la respuesta
   llegaba antes de esos 300 ms el guardado pendiente se ejecutaba después y
   escribía A otra vez en `localStorage`. Medición sobre la base: justo
   después de publicar A, `localStorage` estaba vacío; 600 ms después
   contenía `<p>AAAA</p>`. Con un clic en Post menos de 300 ms después de la
   última tecla pasa siempre.
2. **El formulario nuevo quedaba anidado y el refresco sobrescribía el
   editor.** `create.turbo_stream.erb` usaba `turbo_stream.update` con el
   partial `_new`, que ya trae el `div#new_comment_card_…`. Cada publicación
   dejaba ese `div` dentro de otro con el mismo id. En el siguiente refresco de
   la tarjeta (`broadcasts_refreshes`, que llega con cada comentario de otra
   persona o agente), idiomorph compara contra el HTML del servidor, que tiene
   un solo nivel. Por eso no emparejó `.comment__body[data-turbo-permanent]` y
   morfeó el formulario: el registro de eventos muestra
   `turbo:before-morph-element` y `turbo:morph-element` sobre `LEXXY-EDITOR`,
   que no ocurren cuando el `div` permanente se empareja.
   `turbo:morph-element->local-save#restoreContent` pone entonces en el editor
   el borrador guardado, sin mirar lo que el editor muestra.

Con los dos juntos se produce el reporte: tras publicar A, el borrador
guardado es A; un refresco mientras se escribe B pone A en el editor. Medición
en una prueba de sistema sobre la base: se publica A, se escribe B, llega un
refresco; el editor muestra A y al enviar se guarda `["AAAA", "AAAA"]`.

Si el borrador ya no es A (defecto 1 corregido), el defecto 2 todavía pierde
texto: el borrador guardado puede tener más de 300 ms y el refresco borra las
últimas teclas. La prueba lo mide: con sólo el defecto 1 corregido, el caso 1
falla 2 de 3 veces con `["Segundo B: línea uno"]` en lugar de
`["Segundo B: línea uno", "línea dos"]`. Con sólo el defecto 2 corregido, A
sigue en `localStorage` y vuelve al abrir otra vez la tarjeta (caso 2).

## Corrección

- `create.turbo_stream.erb` usa `turbo_stream.replace`: el DOM tiene la misma
  forma que el HTML del servidor y el morph vuelve a respetar
  `data-turbo-permanent`.
- `local_save_controller.js` guarda con un temporizador propio. En
  `turbo:submit-start` cancela el guardado pendiente y escribe como borrador
  exactamente el contenido enviado. En `turbo:submit-end` guarda el editor
  actual. Si el envío tuvo éxito y el editor contiene exactamente lo enviado,
  borra el borrador; si se escribió durante la petición, guarda ese texto. Un
  envío fallido guarda el editor actual. Al desconectarse ejecuta el guardado
  pendiente. El formulario de edición de la tarjeta usa el mismo controlador
  y recibe la misma acción `submit-start`.

## Reproducción en un navegador real

Servidor de desarrollo de este worktree (SQLite local con la semilla de
desarrollo, Cable `solid_cable`, Chrome mediante `bin/agent-browser`), en una
tarjeta creada sólo para la prueba. No se usó ninguna tarjeta de negocio ni el
Fizzy instalado. El comentario «de otra persona» se publicó por la API JSON de
la tarjeta desde la misma sesión: su `broadcasts_refreshes` llega por Cable
como en uso real. La escritura continua se simuló con `insertText`, una letra
cada 100 ms, y el comentario externo a los 1,5 s.

- **Base `013bf8d61`:** se publica A4 con un clic inmediato en Post. Después,
  `localStorage` contiene A4 y hay dos `div#new_comment…` anidados. Mientras se
  escribe «Comentario B4 escrito sin pausas mientras llega el refresco», llega
  el refresco. El editor queda con «in pausas mientras llega el
  refrescoComentario A4: sexto» y al enviarlo se guarda ese texto: A4 se
  publica otra vez y el principio de B4 se pierde.
- **Con la corrección:** el mismo guion deja `localStorage` vacío tras A4, un
  solo `div#new_comment…`, y el editor conserva B4 completo. Se guardan
  «Comentario A4: sexto» y «Comentario B4 escrito sin pausas mientras llega el
  refresco», cada uno una vez. También se publicaron A, B y C (C multilínea con
  `<b>&amp; "comillas" 'ñ' €`) con refrescos entre ellos, se salió al tablero
  y se volvió: el editor quedó vacío, sin borrador, y la tarjeta no tiene
  comentarios duplicados.

## Autoría antes de escribir las pruebas

Archivo: `test/system/comment_submission_test.rb`.

- **Contrato:** cada comentario enviado desde el formulario se guarda una vez
  y con el texto que el editor muestra y que el formulario envía. El borrador
  local contiene sólo texto que todavía no se envió. Dueños: `local-save`,
  `cards/comments/_new.html.erb`, `create.turbo_stream.erb` y Lexxy. La
  frontera es el navegador real con Turbo, Stimulus, Lexxy y el servidor de
  prueba.
- **Regresión:** volver a `turbo_stream.update` hace fallar el caso 1
  (medido: 2 de 3 con el resto de la corrección). Un guardado diferido que
  escriba el contenido enviado después del éxito hace fallar el caso 2.
  Borrar el borrador sin comparar su contenido hace fallar el caso 3.
- **Cobertura:** `comment_input_test.rb` publica un solo comentario y no
  refresca la tarjeta. `card_refresh_test.rb` refresca la edición de la
  tarjeta, no el formulario de comentario nuevo. `ai_suggestion_test.rb` usa
  el borrador sólo como condición para no sugerir. Ninguna publica dos
  comentarios seguidos ni comprueba `localStorage` después del envío.
- **Seam:** no se añade API productiva. El comentario de otra persona se crea
  en la base y la prueba inserta el mismo `<turbo-stream action="refresh">`
  que entrega Cable, justo después de la última tecla, para que llegue con el
  guardado del borrador todavía pendiente. El contenido enviado se lee de
  `fetchRequest.body` en `turbo:submit-start`. La demora, la retención hasta
  que la prueba la libera y el error de red envuelven `window.fetch` sólo para
  los POST a `/comments`; no sustituyen
  Turbo ni el controlador. El clic en Post ocurre dos frames después de la
  última tecla, como un toque rápido.

Casos:

1. A, B (multilínea) y C (con `<b>&amp; "comillas" 'ñ' €`) seguidos. B y C
   se escriben en dos partes con una pausa, y la tarjeta se refresca justo
   después de la segunda. Cada uno: editor, payload
   y comentario guardado coinciden; los comentarios nuevos son exactamente
   los enviados.
2. Escribir, pausar (se guarda el inicio como borrador), añadir texto y
   publicar enseguida; salir al tablero y volver: el editor está vacío y no
   hay borrador.
3. Texto escrito mientras el envío anterior sigue en curso (POST demorado
   1,5 s): queda en el editor nuevo y en el borrador.
4. Error de red: el texto sigue en el editor y en el borrador, sin comentario
   nuevo.
5. Rechazo del servidor (tarjeta pasada a borrador, 403): igual que el caso 4.
6. Durante un envío retenido se añade texto, se guarda, se borra y la
   respuesta llega enseguida: el editor nuevo queda vacío y sin borrador.

## Evidencia RED y GREEN

Prueba candidata de RED y GREEN: `test/system/comment_submission_test.rb`,
SHA-256 `5dee3328651dcfaf8b44352228a7a53e992cf7b494744b8f11fac55c63ea411e`.
La versión entregada (SHA-256 `a7312b8e42da90e63e0f7954fae3b8832c0ca2af4827d8b7956908a9ea2ea683`) sólo agrega
`before_teardown`, que borra el borrador de la tarjeta antes de que Capybara
reinicie la página. Sin él, los borradores de los casos 3 a 5 aparecían en el
editor de `comment_input_test.rb` cuando corría después en el mismo navegador
(2 fallos y 1 error). Con él, las clases `comment_submission`,
`comment_input`, `ai_suggestion` y `markdown_paste` juntas pasan con tres
semillas: 27 casos, 271 aserciones.
Base de `fizzy-custom`: `013bf8d610933761a5b353ebf8205ee360282e22`
(`origin/main`, sin la corrección). Se exportó con `git worktree add --detach`
en el scratchpad de la sesión, fuera de cualquier worktree de tarjeta, y se
eliminó al terminar. Se copió sólo la prueba candidata y se preparó su base
con `RAILS_ENV=test bin/rails db:drop db:create db:schema:load`.

Ruby 4.0.9 (mise), Lexxy 1.0.1, turbo-rails 2.0.23, SQLite, modo OSS,
Chrome headless en Linux. Comando, desde la exportación (RED) y desde
`fizzy-custom/` (GREEN), con semillas 2341 a 2345:

```sh
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT \
  -u RUBYLIB -u BUNDLE_PATH \
  PATH="$HOME/.local/share/mise/installs/ruby/4.0.9/bin:$PATH" \
  bin/rails test test/system/comment_submission_test.rb --seed <semilla>
```

Se antepone el Ruby de mise al `PATH`: este shell tiene `/usr/bin` antes y
`mise exec` solo no basta.

- **RED (semillas 2341 a 2343, salida 1 cada vez):** 5 casos, 37
  aserciones, 3 fallos, sin errores.
  - Caso 1 falla 3 de 3: tras el refresco el editor muestra
    `["Segundo B: línea uno"]`; «línea dos» se perdió.
  - Caso 2 falla 3 de 3: `localStorage` contiene el comentario ya enviado.
  - Caso 3 falla 3 de 3: el editor nuevo queda vacío; el texto escrito
    durante el envío se pierde.
  - Casos 4 y 5 pasan en la base: el envío fallido ya conservaba el texto.
    Son protección del criterio de aceptación sobre el nuevo camino de
    `submit`. Excepción RED explícita para ellos.
- **GREEN (semillas 2341 a 2345, salida 0 cada vez):** 5 casos, 52
  aserciones, sin fallos, errores ni omisiones.

Una versión anterior de la prueba usaba el broadcast real de Cable
(`perform_enqueued_jobs`, como `card_refresh_test.rb`). Fallaba de forma
intermitente con la corrección: después de un morph, las fuentes
`turbo-cable-stream-source` de la tarjeta perdían `connected` y algunos
broadcasts no llegaron a la página. No se investigó más esa causa. El
broadcast real sí se verificó en el navegador (sección anterior).

## Validación del repositorio

Antes del rebase sobre `922d79d57` (sólo pruebas y documentación de esperas automáticas), `bin/rails test` pasó con 3.188 casos,
17.793 aserciones, 5 omisiones, sin fallos ni errores. `PARALLEL_WORKERS=1
bin/rails test:system` pasó con 122 casos, 931 aserciones, sin fallos ni
errores. Esa ejecución usó una versión anterior de la prueba nueva. Con la
versión entregada, `PARALLEL_WORKERS=1 bin/rails test:system --seed 2341`
pasó con 122 casos, 932 aserciones, sin fallos, errores ni omisiones. El
código de producción es el mismo en las dos ejecuciones. `bin/rubocop` del archivo
nuevo, `script/check_agents_docs` y `git diff --check` pasan.

## Revisión, ronda 1

Los dos gates (Dédalo y `bin/signoff`) marcaron el mismo bloqueante: la
primera versión cancelaba el guardado pendiente al enviar. Si se escribía
«Comentario ya», se pausaba, se añadía « enviado» y se publicaba enseguida,
el borrador seguía siendo «Comentario ya», no coincidía con lo enviado y
volvía al abrir la tarjeta. El caso 2 se amplió con esa secuencia: falló 2 de
2 contra esa versión (`Expected "<p>Comentario ya</p>" to be nil`). La
corrección escribe el contenido enviado como borrador en `submit-start`. Con
ella, las clases `comment_submission`, `comment_input`, `ai_suggestion`,
`markdown_paste` y `card_refresh` juntas pasan con tres semillas: 31 casos,
297 aserciones.

Prueba final: SHA-256
`3d75c6a8a4dde54ab50f41f43fb3d50a13897ddac966609b328eac4ceea6d61f`. Sobre la
base `922d79d57` (exportación temporal, eliminada después; dos semillas) falla
con 3 fallos en 5 casos, igual que antes: caso 1 `["Segundo B: línea uno"]`,
caso 2 `Expected "<p>Comentario ya enviado</p>" to be nil`, caso 3 editor
vacío. Con la corrección, `bin/rails test` pasó con 3.190 casos, 17.809
aserciones, 5 omisiones; `PARALLEL_WORKERS=1 bin/rails test:system --seed
2342` pasó con 122 casos, 932 aserciones; ambos sin fallos ni errores.

## Revisión, ronda 2

`bin/signoff` dio PASS (huella `37e2bcc8175d`). El gate de Dédalo marcó un
bloqueante nuevo: con un envío lento, si se añadía texto durante la petición,
se guardaba y se borraba justo antes de la respuesta, el éxito conservaba el
borrador con el texto borrado y reaparecía. Secuencia de bloqueantes de la
serie de Dédalo: 1→1.

Se agregó el caso 6. Retiene el POST con una promesa que la prueba libera
justo después de borrar. Evidencia RED del caso 6:

- **Base:** `cabf50e73d9aa99463ad1a616108d57036aec6ea`, el commit revisado
  en la ronda 2 (sin esta corrección), exportado con `git worktree add
  --detach` en el scratchpad y eliminado después. Se copió sólo la prueba
  candidata y se preparó su base con
  `RAILS_ENV=test bin/rails db:drop db:create db:schema:load`.
- **Prueba:** `test/system/comment_submission_test.rb`, SHA-256
  `fda9d0a5a6bf33a1b06cbaa0fc271ea22103522cd5c6bcedc6d5a07716fe35ab`, la
  misma versión que se entrega.
- **Comando**, con el entorno de la sección «Evidencia RED y GREEN» y las
  semillas 2341, 2342 y 2343:
  `bin/rails test test/system/comment_submission_test.rb -n "/added and removed/" --seed <semilla>`.
- **RED:** salida 1 las tres veces; 1 caso, 9 aserciones, 1 fallo. El editor
  nuevo muestra `["Comentario enviado y borrado"]` en lugar de `[]`.
- **GREEN:** el mismo comando desde `fizzy-custom/` con la corrección: salida
  0 las tres veces; 1 caso, 10 aserciones.

 La corrección hace
que, tras un éxito, un editor igual a lo enviado borre el borrador; un envío
fallido ya no se compara con un envío anterior. Con ella, las clases
`comment_submission`, `comment_input`, `ai_suggestion`, `markdown_paste` y
`card_refresh` juntas pasan con tres semillas: 32 casos, 307 aserciones.
`bin/rails test` pasó con 3.190 casos, 17.809 aserciones, 5 omisiones.
`PARALLEL_WORKERS=1 bin/rails test:system --seed 2343` dio 123 casos, 935
aserciones y un fallo: `card_stage_navigation_test.rb:21` espera el título
`Done card refreshed` y encuentra `The logo isn't big enough`. Es el mismo
fallo intermitente que `docs/test-audits/handy-1862.md` registra también en la
base. Repetido solo con la misma semilla, falló 1 de 2 veces. No toca
comentarios ni borradores; no se investigó.

## Lo que no se verificó

- No se leyó producción: la tarjeta no autoriza leer la base ni los logs del
  Fizzy instalado. No se sabe cuántos comentarios duplicados hay ni se tocó
  ninguno.
- El navegador y el dispositivo del reporte no se conocen. La reproducción
  usa Chrome en Linux.
