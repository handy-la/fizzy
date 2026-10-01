# Handy 512: sugerencias sin bloquear la web

## Autoría antes de editar pruebas

- Contrato: POST acepta una generación sin esperar al proveedor; GET entrega sólo el resultado de la persona y tarjeta autorizadas. Las sugerencias no modifican tarjetas ni publican comentarios. La frontera es HTTP + Active Job.
- Regresión: volver a llamar RubyLLM dentro de POST rompe la respuesta 202 y el trabajo pendiente. Perder la exclusión crea trabajos duplicados. Compartir resultados entre personas rompe autorización.
- Cobertura: `Cards::SuggestionsControllerTest` ya protege contexto, autorización y ausencia de publicación, pero esperaba generación síncrona. Se amplían esos casos y se agregan deduplicación, consulta y fallo del trabajo.
- Seam: rutas productivas POST/GET y la cola Active Job existente. WebMock sustituye sólo el proveedor externo; no implementa deduplicación ni autorización. No se agrega acceso exclusivo de pruebas.

## Navegador

La base reproduce POST /897362094/cards/1/suggestion con 503 al desplazar el editor a la pantalla, sin enfoque ni edición. Prueba local con datos de fixtures y proveedor sin configurar. No se usan datos reales.

## Autoría de pruebas del navegador

- Contrato: sólo escribir en la descripción vacía de título y enfocar con teclado o puntero el comentario vacío inicia POST. No lo inician visibilidad, carga, eventos sintéticos ni restauración. El texto escrito después prevalece.
- Regresión: restituir IntersectionObserver hace fallar el cero de solicitudes antes del enfoque; aceptar lexxy:change sintético hace fallar el caso de restauración. El campo conserva texto y el contador observa fetch del controlador real.
- Cobertura: se amplía `AiSuggestionSystemTest`, que antes exigía el disparador por visibilidad y usaba un evento sintético para títulos. La capa HTTP anterior no observa eventos confiables del navegador.
- Seam: interceptar fetch en la página sólo controla tiempo y texto del proveedor. Los eventos de teclado y puntero llegan por Selenium, sin construir isTrusted. No se cambia la API productiva para probar.

## Evidencia RED histórica

Base completa: `4d5015ffbe5450e1eb0728307112e03bdc6a01b7`.
Exportación aislada con `git archive` en `.context/fizzy-base`, sin otro worktree
ni el source checkout. Se aplicaron sólo los archivos de pruebas candidatos.
Ruby de mise 3.4.8, SQLite, Chromium y chromedriver locales.

En el directorio exportado:

```
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 mise exec -- bin/rails test test/controllers/cards/suggestions_controller_test.rb
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 mise exec -- bin/rails test test/system/ai_suggestion_test.rb
```

HTTP: salida 1, 7 pruebas, 5 fallos. La base devuelve 200/503 en vez de 202 y
acepta la descripción corta con 200 en vez de 204. Sin errores de carga.
Navegador: salida 1, 5 pruebas, 4 fallos. Las descripciones cortas y restauradas,
y la visibilidad del comentario, producen 1 solicitud en vez de 0.
El caso añadido de reconexión y Tab comprueba el mismo contrato de ciclo de
vida; el RED histórico inicial ya identifica el disparador prohibido.

## Validación del servidor lento

Servidor local con fixtures, Puma con un solo hilo y sustitución temporal del
proveedor por una espera de 15 segundos (fuera del código versionado). POST
real devuelve 202; GET consulta el estado hasta 200. Durante la espera, GET de
otra tarjeta devuelve 200 en 32 ms. El autoguardado de la descripción devuelve
200 antes del resultado. La persona puede escribir y publicar su propio
comentario mientras espera. La respuesta de IA no sustituye ese texto.

No se verificó la latencia interna de Fireworks ni el despliegue de producción.
La comprobación de transporte usa el servidor local; la cola de producción
conserva Solid Queue y añade un worker exclusivo, con concurrencia global 1.

## Resultado final

El comando combinado de las dos pruebas candidatas en la exportación base
(13 casos, incluida reconexión por Tab) terminó con salida 1: 10 fallos de
contrato y ningún error de carga. En el arreglo, los casos HTTP dan 7 pruebas,
84 aserciones, sin fallos; los casos de navegador dan 6 pruebas, 31 aserciones,
sin fallos.

Suite OSS, ejecutada en `fizzy-custom/`:

```
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=2 mise exec -- bin/rails test
SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 mise exec -- bin/rails test:system
```

Resultado: 1 739 pruebas, 6 614 aserciones, 0 fallos, 0 errores, 6 omisiones;
suite de navegador: 28 pruebas, 131 aserciones, 0 fallos, 0 errores.
Rubocop de los archivos Ruby modificados: sin infracciones.

Las peticiones del navegador comprueban carga, desplazamiento, enfoque
programático, restauración y eventos sintéticos sin generación; escritura real
con debounce y enfoque real con generación. Las pruebas de ciclo de vida
comprueban reenfoque pendiente, resultado editable y reconexión de Stimulus.
Una edición nueva del título reemplaza la solicitud anterior por token: los
trabajos pendientes obsoletos se omiten y un resultado anterior no puede
sobrescribir el nuevo. Reenfocar el comentario no crea otro trabajo pendiente.

La base incluye una ejecución inicial de toda la suite de navegador que falló
en `MarkdownPasteTest`; la suite completa del arreglo pasó. No se atribuye ese
fallo ajeno a esta corrección ni se modifica esa prueba.
