# Handy 541: autoría de pruebas

Base: `12ed9297d997634f70cb24f6cf4e2e5f536a3bd3` (fizzy-custom).

## Contratos antes de editar las pruebas

1. Backend: el recurso de sugerencia devuelve un estado terminal, conserva el
   resultado desde el fin de la generación y permite reintentar un fallo sin
   duplicar un trabajo pendiente. La frontera es HTTP, el job y el proveedor.
   Regresiones: salida vacía/truncada tratada como válida, vigencia consumida
   en cola, fallo reutilizado. La prueba existente de fallo sólo comprueba 503;
   la de reutilización sólo cubre éxito. Se amplían esos casos. No se agrega
   un seam: WebMock intercepta el HTTP productivo del proveedor.
   Se incluye respuesta completa mayor que el límite local (rechazar, no
   recortar) y un worker interrumpido: se usa el estado running almacenado y
   el barrido productivo, sin inventar un worker de prueba. La base no tiene
   las columnas de inicio/fin; excepción RED de ese estado nuevo. La regresión
   histórica de pending vencido sí dio RED. La prueba de interrupción observa
   que el barrido libera el reintento y que el job antiguo no llama al proveedor.
2. Transporte: sólo el usuario dueño con acceso actual a la tarjeta obtiene
   el resultado, con su token y revisión. La frontera es Action Cable real
   y su recuperación al conectar. Regresiones: un canal compartido entrega
   texto a otro usuario, acceso revocado conserva lectura, reconexión genera
   otra llamada. HTTP ya cubre parte de autorización; no cubre suscripción ni
   recepción. El canal y `recover` serán APIs productivas del navegador.
3. Editor: propuesta visible sin valor ni borrador ni publicación; Enter simple
   acepta una sola vez; edición propia, IME, Shift y Ctrl/Meta conservan su
   significado. Regresión: copiar la propuesta al recibirla o interceptar Enter
   después de Lexxy. Se amplía el caso existente de comentario y se conservan
   sus casos de foco, reconexión y borrador. No hay seam productivo nuevo: el
   navegador usa Lexxy y el recurso HTTP normales; las respuestas controladas
   sólo viven en el navegador de prueba. La prueba de Cable separada debe usar
   transporte real, pues ese control de fetch no lo verifica.
4. Proveedor y prompt: el HTTP efectivo selecciona Kimi K3 Fast, desactiva
   razonamiento y propone respuestas simples a solicitudes recientes sin
   afirmar trabajo ejecutado. Regresión: alias Flash, parámetros ignorados o
   instrucciones que inventan hechos. Se amplía la inspección del contexto
   existente, con aserciones del payload de proveedor. El prompt es un contrato
   explícito pedido por la persona; no se exige redacción exacta completa.

## Evidencia inicial

En navegador sobre la base, una respuesta controlada insertó
`<p>Sí, apruebo ejecutar las comprobaciones pendientes.</p>` en Lexxy y
habilitó Post. Captura antes: adjunto de la tarjeta al entregar.
No se retirarán pruebas ni seams.

El contrato del editor incluye el guardado local después de su debounce:
Lexxy representa un campo vacío con `<p><br></p>`. Ese valor tampoco debe
guardar un borrador. Se amplía el mismo caso de placeholder con espera del
guardado. El caso de borrador existente conserva texto real. La frontera es
el almacenamiento del navegador, sin seam nuevo; `Lexxy.isEmpty` es API
productiva del editor. Una regresión guarda marcado vacío o la propuesta sin
aceptarla. El caso previo sólo inspeccionaba localStorage antes del debounce.

El canal es nuevo: no existe una prueba histórica ejecutable de ese transporte.
Excepción RED para las pruebas nuevas del canal: en la base no existe el canal;
un error de carga no se contará como RED. Se verificará autorización, recepción
real y recuperación tras la implementación. El RED del editor y los estados
HTTP sí debe ejecutarse contra la base antes de corregir.

## Sustitución del caso de reconexión

Se conserva `test/system/ai_suggestion_test.rb`, dueño `ai-suggestion`, pero el
caso de foco por Tab ya permite repetir el POST cuando su respuesta se perdió.
La prueba previa retenía un bloqueo de cinco minutos incluso sin token recibido;
ese contrato se elimina por petición explícita de recuperación. No se elimina
el contrato de una sola generación: lo verifican el caso HTTP de reutilización
(una encolación) y el nuevo caso Cable (una llamada a Fireworks tras reconectar).
No se retira un seam; el control de fetch sólo existe dentro de la página de
prueba. El riesgo de reintento duplicado se observa ahora en la frontera del
proveedor. Historia conocida: el caso estaba en la base citada; no se auditó
su commit de introducción. Decisión: sustituir la restricción de un POST por
recuperación de POST y conservar deduplicación del job.

## RED y GREEN

Desde `fizzy-custom`, sobre la base citada sin corrección, se aplicó la versión
inicial de las pruebas candidatas y se ejecutó:

```sh
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u RUBYLIB \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=0 \
  mise exec -- bin/rails test test/controllers/cards/suggestions_controller_test.rb \
  test/system/ai_suggestion_test.rb
```

Resultado RED: exit 1; 15 casos, 118 aserciones, cuatro fallos, cero errores.
El placeholder no existía, el vencimiento y fallo devolvían 503 en vez de
estado terminal y la salida vacía carecía de estado failed. Evidencia de sesión:
`.context/handy-541-red.log` del workspace. La versión inicial del caso de editor
exigía valor literal vacío; se corrigió a conservar el valor vacío de Lexxy,
que también puede ser marcado estructural sin texto.

El caso ampliado de guardado vacío también dio RED antes de corregir
`local-save`: exit 1; una prueba, ocho aserciones; se encontró `<p><br></p>` en
localStorage. Comando anterior con sólo `test/system/ai_suggestion_test.rb -n
/placeholder/`; evidencia `.context/handy-541-empty-draft-red.log`. Es evidencia
adicional sobre el cliente parcialmente corregido, no reemplaza el RED histórico.

GREEN del mismo conjunto inicial, con casos ampliados: los casos HTTP pasan en
la suite y los de editor pasan en `test:system`. El caso Cable usa adapter async
real durante su ejecución, restaurado al terminar. Conserva sesión HTTP,
WebSocket autenticado, suscripción, broadcast y recuperación reales; sólo
Fireworks está controlado por WebMock. Quitar la asociación Stimulus mientras
está desconectado restaura el placeholder normal y recupera la misma solicitud
al asociarla de nuevo. No basta con observar un placeholder que nunca desapareció.

Validación de sesión (Ruby 3.4.8, SQLite, SAAS=false):

- `PARALLEL_WORKERS=2 ... bin/rails test`: 1.757 casos, 6.786 aserciones,
  cero fallos, cero errores; seis omisiones preexistentes.
- `PARALLEL_WORKERS=1 ... bin/rails test:system`: 31 casos, 157 aserciones,
  cero fallos, cero errores.
- RuboCop sobre los nueve archivos Ruby de implementación/pruebas: sin ofensas.
- Navegador manual: Kimi real por RubyLLM, respuesta por Cable sin GET periódico,
  placeholder con Post deshabilitado y sin borrador. HTTP controlado de proveedor
  de 25,1 s y desconexión durante generación; reapertura recuperó el resultado.
  Capturas del editor con el mismo usuario, tema y tamaño: base exportada sin
  corrección y estado final. La base usa el mismo texto sintético mediante una
  respuesta HTTP controlada; no es una captura de producción.

Qué no se pudo verificar: no se mató un worker de producción, no se midieron
percentiles de latencia de producción ni se ejecutó MySQL. El barrido y los
estados vencidos se verifican con reloj/control de base local. Los límites de
latencia se justifican como margen, no como estimación de percentiles. No hay
cambio en Android, Rails de Handy ni Help Center de clientes.

El caso de fallo visible del cliente protege el reintento después de reconectar
el formulario. Frontera: UI, SessionStorage y POST. Regresión: guardar descarte
sin conservar el fallo oculta el botón de reintento al volver. La prueba previa
sólo observa el backend, por lo que no detecta este riesgo de ciclo de vida.
Usa los mismos controles HTTP de la página, sin API productiva de prueba.

## Evidencia adicional pedida por signoff (ronda 1)

Candidata final de `test/system/ai_suggestion_test.rb`: SHA-256
`24552b8d46968f707bf925c249b8cf771877e4044f9575b605b9015a8f66539a`.
Se copió ese archivo sobre una exportación `git archive` de la base
`12ed9297d997634f70cb24f6cf4e2e5f536a3bd3`, en
`<workspace>/.context/fizzy-base`. No se cambió el código de esa base ni se usó
el checkout fuente. Se preparó su SQLite de test con `RAILS_ENV=test bin/rails
db:prepare`, usando la misma Ruby 3.4.8.

Comando exacto, con cwd de la exportación para RED y cwd `fizzy-custom` para
GREEN (mismo archivo candidato y entorno):

```sh
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u RUBYLIB \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=0 \
  /home/hermes/.local/share/mise/installs/ruby/3.4.8/bin/ruby bin/rails test \
  test/system/ai_suggestion_test.rb -n '/terminal_failure|IME_and_Shift/'
```

RED: exit 1; dos casos, seis aserciones, dos fallos, cero errores. El caso de
reintento falla porque no existe el botón «Reintentar sugerencia» tras recibir
un resultado failed. El caso IME/Shift/Ctrl falla al preparar su estado de
propuesta: la base inserta el texto inmediatamente y no tiene placeholder con
aceptación. Log: `.context/handy-541-additional-red.log`.

GREEN: exit 0; dos casos, catorce aserciones, cero fallos/errores.
Log: `.context/handy-541-additional-green.log`.

**Excepción RED explícita para la protección IME en sí:** el fallo histórico
anterior demuestra la ausencia del estado de aceptación, no una aceptación
durante IME. La base no tiene ese handler y no permite preparar una propuesta
pendiente en un editor vacío. No se cuenta el fallo de preparación como RED del
handler IME. El contrato sí se verifica en la candidata: una fase de composición
con editor enfocado no acepta la propuesta con Enter nativo.

Validación alternativa específica: se exportó la corrección del commit
`8b7019544287fb5218e530c877eff7ef0b1060c9` a
`.context/fizzy-mutant`, con la misma candidata final. Sólo en esa copia se
quitaron `event.isComposing`, `this.#composing` y `event.keyCode === 229` de la
condición de aceptación. Se ejecutó el comando anterior con `-n
'/IME_and_Shift/'`: exit 1; un caso, cuatro aserciones, un fallo, cero errores.
La aserción posterior al Enter durante composición encuentra «Sí, adelante.»
en el valor del editor. Log: `.context/handy-541-ime-mutant.log`. La candidata
sin esa mutación pasa. Esto prueba sensibilidad de la protección actual;
no reemplaza el RED histórico ni afirma que la base tuviera ese handler.

La prueba instala dos listeners temporales de captura en el editable, sólo en
el navegador de prueba, para impedir que Lexxy inserte su marcador de
composición. Sin ese aislamiento, el campo deja de estar vacío y otro guard
oculta la regresión; esa primera mutación pasó y no se contó como evidencia RED.
Los listeners no aceptan texto ni implementan el comportamiento esperado. La
aceptación y su bloqueo los realiza el controlador productivo. No se agregó
seam de producción. Límite: no se operó un teclado IME físico; se delimitó su
fase con CompositionEvent y se usó Enter nativo de Selenium.
