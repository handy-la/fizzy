# Cuotas y turnos de webhooks: Handy 942

## Autoría antes de editar las pruebas

- **Contrato:** la creación admite hasta 5 webhooks por tablero y 20 por cuenta,
  incluidos inactivos; la petición número 11 en un minuto recibe 429. La
  admisión de entregas admite 100 pendientes o en progreso por cuenta. Los
  avisos se agrupan; el envío conserva el orden por tarjeta y cambia de cuenta
  en cada turno. Hay hasta 8 intentos por entrega y 60 reintentos por hora y
  cuenta. Los workers generales no consumen colas de webhooks.
- **Regresión:** quitar la admisión permite la fila 6/21/101; quitar el límite
  HTTP permite crear y borrar sin freno; avisar por entrega crea jobs duplicados;
  elegir siempre la cuenta menor impide el turno de otra cuenta; quitar los
  presupuestos permite nuevos HTTP después del límite; usar una cola general
  para webhooks hace que sus workers esperen respuestas externas.
- **Cobertura:** `WebhooksControllerTest` prueba creación válida y autorización,
  pero no cuotas ni ritmo. `Webhook::DeliveryTest` prueba reintentos por 24 horas,
  orden y bytes, pero no cuenta agregada ni reparto de turnos. Se conservan esos
  contratos y se adapta su comprobación del aviso al planificador agrupado.
  Los nuevos casos de recursos usan entradas productivas y observan filas,
  respuestas HTTP, número de jobs y llamadas HTTP. La configuración de workers
  tiene una prueba independiente del consumidor de colas.
- **Seam:** `Webhook#save`, `Webhook#trigger`, `Webhook::Delivery#deliver` y la
  ejecución de Active Job son entradas productivas. El nuevo planificador lo
  consumen los callbacks y el barrido periódico. No se agrega API exclusiva de
  pruebas. WebMock sustituye sólo la frontera externa HTTP; no decide cuotas,
  selección ni estado. Los límites esperados se expresan como valores del
  contrato, no se calculan con la implementación.

## Evidencia de ejecución

Base exportada con `git archive`:
`1cde149e8e7b1f71fdcd25479ccb7ac3f5578f00` del repo `fizzy-custom`.
No se usó otro worktree ni el source checkout. Se copiaron sólo las dos
candidatas de recursos y controlador.

SHA-256 de las candidatas finales:

- `resource_limits_test.rb`:
  `bbbffc1fbff279973a708e89dcc90cadfbf17a36a217bdadd20eb656e98edf55`.
- `webhooks_controller_test.rb`:
  `bd686bf113fa3636b260dc5c7c6aceb857e4ab1259362107259b53c8f18bebed`.

Entorno: Ruby 3.4.8 de mise, SQLite, OSS. Desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ruby -e 'Dir.chdir("../.context/handy-942-base"); exec("./bin/rails", "test", "test/models/webhook/resource_limits_test.rb", "test/controllers/webhooks_controller_test.rb")'
```

RED histórico: salida 1; 32 casos, 226 aserciones, 11 fallos, sin errores.
Se admitieron webhooks y entregas sobre la cuota, se crearon 20 jobs donde debe
haber uno, los workers generales incluían webhooks, una cuenta tomó los dos
primeros turnos, se aceptó el reintento 61 y se enviaron receptores de una
cuenta con otro envío activo. Las pruebas de compatibilidad no se presentan
como incidentes adicionales. Evidencia local: `handy-942-red-final.log`.

GREEN enfocado, mismo entorno con `mise exec -- bin/rails test
 test/models/webhook_test.rb test/models/webhook
 test/controllers/webhooks_controller_test.rb`: 87 casos, 470 aserciones,
sin fallos ni errores antes de agregar los dos últimos casos de recuperación y
saturación. Los dos casos adicionales pasan también en la suite final.

Suite final: mismo entorno, `PARALLEL_WORKERS=4 mise exec -- bin/rails test`:
salida 0; 1.941 casos, 7.882 aserciones, sin fallos ni errores, 6 omisiones.
`bin/rubocop` en los 18 archivos Ruby cambiados: salida 0, sin infracciones.
La migración se aplicó en la base de prueba SQLite y ambos esquemas publicados
incluyen sus tablas e índice. El esquema MySQL se mantiene conforme a la
migración; no se ejecutó contra un servidor MySQL.

## Protocolo del planificador

`Webhook::DispatchTest` observa HTTP, la ejecución de jobs y el lease durable:
una copia del mismo job no puede liberar el envío activo; un token vencido no
puede enviar; los sucesores bloqueados no crean avisos individuales; los jobs
antiguos sólo avisan al planificador. El consumidor productivo es
`Webhook::DispatchJob`, y el barrido llama `Webhook::Dispatch.recover`.

Excepción RED explícita para este protocolo nuevo: en la base no existen ni la
tabla ni el job con token. Un NameError no demostraría una regresión. El RED
histórico de las entradas anteriores cubre los 11 fallos del problema, incluido
el número de jobs, el turno de otra cuenta y la concurrencia agregada. Se
verificará además la sensibilidad de los casos de token con mutaciones en una
exportación temporal. No se retira cobertura: las pruebas de bytes, orden,
plazos y fallos HTTP se conservan, con ejecución por el modelo; el caso de
compatibilidad comprueba el nuevo papel del job antiguo.

El caso de recuperación sin respuesta protege un intento interrumpido cuando
el presupuesto ya se agotó. La respuesta puede ser nil; la finalización debe
liberar el cupo y contar el fallo sin otro HTTP. No lo cubría el caso de
interrupción anterior, que reanudaba con presupuesto disponible. Usa estado
persistido de entrega y el barrido productivo, sin seam nuevo.

El caso de saturación ejecuta `DeleteUnusedTagsJob` y
`Account::IncinerateDueJob` de otra cuenta mientras quedan 100 entregas
pendientes. Observa el borrado real y que no hubo HTTP. Complementa la prueba
RED de configuración de workers: el adaptador de prueba ejecuta las colas
seleccionadas, por lo que este caso no mide la latencia de workers vivos.


## Sensibilidad y límites

En una exportación temporal del código corregido, quitar la exclusión de
`running` hizo que el caso de job duplicado fallara: el token activo se volvió
nil. Quitar la comprobación de igualdad del token hizo que el caso de token
vencido fallara: hubo un HTTP que debía estar prohibido. Cada ejecución dio
salida 1, un fallo y cero errores. La copia productiva no se modificó. Evidencia:
`handy-942-mutation-duplicate.log` y `handy-942-mutation-token.log`.

El caso de interrupción sin respuesta falló primero con NoMethodError al
clasificar la respuesta nil, sobre la implementación intermedia de esta tarjeta.
Después se usa el código numérico cero para una respuesta ausente; la suite
final confirma la finalización sin HTTP. Este RED intermedio se declara como
sensibilidad adicional, no como RED histórico del job con token.

No se verificaron workers vivos bajo carga, latencia de otros tenants,
MySQL, el bundle SaaS ni un despliegue. El adaptador de Active Job y WebMock
verifican turnos, número de HTTP, estado y ejecución de los jobs normales;
la prueba de configuración comprueba qué colas consumen los workers reales.
La capacidad de un único HTTP global y el descarte al llegar a 100 pendientes
son límites explícitos, descritos en `docs/webhook-resources.md`.

Tras el rebase sobre `b7854be3d5898b0b491e83a29fe45567d3928f32`, se resolvió
únicamente el número de versión de los dos esquemas. La suite completa repitió
el mismo comando: salida 0, 1.959 casos, 7.955 aserciones, cero fallos y errores,
seis omisiones. `script/check_agents_docs` pasó para sus cuatro documentos.
`bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error` dio salida 0,
cero avisos de seguridad y seis avisos ya ignorados. Evidencia local:
`handy-942-suite-rebased.log` y `handy-942-brakeman.log`.
