# Cuotas de suscripciones y aislamiento del envío push

## Autoría antes de editar pruebas

Base: `36bef7b3258ccb9d30bdd92dc83323490353bfe6`.

- **Contrato:** el POST admite cinco suscripciones por usuario, rechaza la
  sexta con 429, sustituye el token del mismo cliente y limita altas a diez
  por diez minutos aunque cambien endpoint, cliente e IP. El pool admite
  como máximo cien envíos por cuenta y cinco envíos simultáneos por cuenta,
  con cincuenta workers globales y turnos entre cuentas. Un descarte identifica
  cuenta y motivo en el log, sin endpoint, claves ni contenido.
- **Regresión:** eliminar el conteo permite la sexta fila; omitir el cliente
  acumula tokens; limitar por IP permite evadir el límite; compartir todos los
  workers permite que una cuenta bloquee otra; ignorar el rechazo oculta pérdidas.
- **Cobertura:** se amplía `users/push_subscriptions_controller_test.rb`.
  Sus casos actuales sólo prueban alta, duplicado, borrado y URL válida.
  `push/subscription_test.rb` sólo cubre URL/DNS. Se conserva esa cobertura.
  La prueba nueva del pool observa entregas reales en threads con puertas
  controladas; `notification/push_target/web_test.rb` sólo sustituye el pool.
- **Seam:** entradas productivas HTTP y `WebPush::Pool#queue`. No se agrega
  una API exclusiva para pruebas. Se sustituye únicamente la entrega HTTP,
  con puertas y contadores independientes del planificador. El rechazo se
  induce en el executor real al apagarlo, sin simular la política del pool.

## Autoría de concurrencia y suscripciones antiguas

- **Contrato:** seis POST simultáneos producen cinco filas y un rechazo.
  Una notificación de un usuario con filas antiguas excesivas entrega sólo
  cinco destinos. La creación directa de una sexta fila también se rechaza.
- **Regresión:** quitar el bloqueo permite pasar el conteo en paralelo;
  quitar el límite de lectura restaura el fan-out histórico; aplicar la cuota
  sólo en el controlador permite omitirla desde otros productores.
- **Cobertura:** los casos seriales anteriores no observan estas fronteras.
  Se agrega HTTP con conexiones independientes y se amplían las pruebas
  existentes del modelo y del consumidor de `queue`.
- **Seam:** ninguno. La prueba HTTP usa registros confirmados y una pausa de
  50 ms en la notificación SQL del conteo para ampliar la ventana de carrera.
  El caso histórico usa inserciones directas sólo para preparar datos antiguos.

## Política productiva

Cuota de cinco dispositivos por usuario. Diez POST por diez minutos, con la
clave del usuario y el store de caché de Rails (Solid Cache en producción).
Una alta repetida por endpoint actualiza sus claves; `client_id` identifica al
navegador, no al proveedor ni al user agent. Es opcional para clientes antiguos.
Cambiar ese identificador no evita la cuota ni el límite de peticiones.
La sustitución y la cuota usan una transacción con UPDATE del usuario antes
de consultar. Una sustitución inválida revierte toda la transacción.

No se borran destinos antiguos de otros clientes. El lector limita cada aviso
a los cinco destinos más recientes. El pool mantiene cien reservas por cuenta,
incluido el trabajo que prepara DNS, espera o ejecuta; cinco workers por cuenta,
cincuenta globales y diez mil reservas globales. Rota las cuentas con trabajo
disponible. El presupuesto se libera al terminar, fallar o rechazar el executor.
La política explícita es descartar el envío nuevo cuando falta presupuesto o
el executor lo rechaza; conserva los envíos aceptados. Se registra cuenta y
motivo, sin mensajes, endpoints o claves. La notificación interna de Fizzy sigue
disponible aunque se descarte el aviso push. Estos presupuestos son por proceso.

## Evidencia RED y GREEN

Ruby 3.4.8 de mise, SQLite, Gemfile OSS. Base exportada con `git archive HEAD`
desde `fizzy-custom/` a `../.context/fizzy-940-red`; HEAD era el SHA completo
indicado arriba. Se copiaron sólo las cinco pruebas candidatas. No se usó
otro checkout. Entorno común, con cwd `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bash -c 'cd ../.context/fizzy-940-red && bin/rails test test/controllers/users/push_subscriptions_controller_test.rb test/controllers/users/push_subscriptions_concurrency_test.rb test/lib/web_push/pool_test.rb test/models/push/subscription_test.rb test/models/notification/push_target/web_test.rb'
```

RED: salida 1; 47 casos, 116 aserciones, ocho fallos y cero errores.
El sexto POST y el undécimo POST aceptan 201 en lugar de 429; seis altas
concurrentes aceptan 201; la creación directa acepta una sexta fila; los
destinos antiguos exceden cinco; una cuenta ocupa seis de los primeros seis
workers; se prepara DNS para 101 envíos; no se registra ningún rechazo.

GREEN: mismo entorno, con `mise exec -- bin/rails test` y los mismos cinco
archivos como argumentos, desde el checkout corregido. Salida 0; 47 casos,
140 aserciones, cero fallos, errores u omisiones.

Suite completa: mismo entorno, `PARALLEL_WORKERS=4 mise exec -- bin/rails test`.
Salida 0: 1.888 casos, 7.522 aserciones, cero fallos, cero errores y seis
omisiones existentes. RuboCop de los diez archivos Ruby del lote y
`git diff --check`: salida 0. Logs locales: `.context/fizzy-940-red.log`,
`.context/fizzy-940-green.log` y `.context/fizzy-940-suite.log`, en la raíz.

Después del rebase sobre `58e1e4a7e`, la suite completa con el mismo comando
da salida 0: 1.911 casos, 7.614 aserciones, cero fallos, cero errores y seis
omisiones. Evidencia: `.context/fizzy-940-suite-final.log`.
`script/check_agents_docs` también pasa (cuatro archivos).

## Identidad de las pruebas

SHA-256 de las pruebas, iguales en RED y GREEN:

- `test/controllers/users/push_subscriptions_controller_test.rb`:
  `a8c362192eec753a6bcd42c0ea0199cf2cd0b55d38a9797bf3815dda3c4f2c9c`
- `test/controllers/users/push_subscriptions_concurrency_test.rb`:
  `58fe99acd512d1848b8554b703edcb25ea835b6e392afc86cce50a36c7754355`
- `test/lib/web_push/pool_test.rb`:
  `d3f1a58dceaa77746ce3a8be1270d1101afe89d7341026b85bb4cf9ca106e2b1`
- `test/models/push/subscription_test.rb`:
  `dc46d47eb1dbf8c1b586e713c18073c2881aec736527de4eb71d3de0f5ecb5dc`
- `test/models/notification/push_target/web_test.rb`:
  `5a539d351bf72cc192a2dd6d275617487178e8f63779315df9ca547746c6ea75`

## Lo que no se verificó

No se ejecutó MySQL, SaaS, navegador ni envío a proveedores externos.
Los tests del pool usan threads y executor reales; sustituyen sólo la entrega
externa por puertas y contadores. El límite HTTP usa MemoryStore en la prueba,
no Solid Cache de producción. No se comprobó un presupuesto distribuido entre
procesos: cada proceso aplica su propia capacidad. El esquema MySQL refleja
la migración, sin haberlo regenerado desde un servidor MySQL.
