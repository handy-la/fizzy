# Consumo único del enlace de acceso

## Autoría antes de editar pruebas

Base productiva: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.

- **Contrato:** un código permite un solo canje y debe estar vigente cuando
  se consume. Dueño: `MagicLink#consume`. Fronteras: dos objetos del mismo
  registro y dos solicitudes HTTP reales con conexiones independientes.
- **Regresión:** devolver el objeto después de un borrado que no afecta filas
  acepta un segundo canje. Validar la vigencia sólo al leer acepta un objeto
  que vence antes del borrado.
- **Cobertura:** `MagicLinkTest#consume` comprueba un canje normal, expiración
  anterior a la lectura y códigos inválidos. No cubre dos objetos ya cargados
  ni vencimiento posterior a la lectura. Las pruebas de
  `Sessions::MagicLinksControllerTest` conservan el binding del correo, pero
  no comprueban sesiones y respuestas ante canjes simultáneos. Se agrega una
  prueba HTTP separada porque necesita fixtures sin transacción y dos clientes.
- **Seam:** no se agrega API productiva. La prueba HTTP usa la notificación
  existente `sql.active_record` para detener ambas lecturas reales del enlace
  antes de continuar. No simula consultas, borrados, autenticación ni sesiones.
  Las esperas tienen límite y los hilos limpian su contexto.

## Evidencia

Se exportó la base con `git archive` a `.context/handy-935-base`, fuera del
repo. Se copiaron sólo las dos pruebas candidatas. La exportación tiene sus
propias bases SQLite. Ruby 3.4.8 de mise, modo OSS (`SAAS=false`).

Comando RED desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- ruby -C ../.context/handy-935-base bin/rails test \
    test/models/magic_link_test.rb \
    test/controllers/sessions/magic_link_concurrency_test.rb \
    test/controllers/sessions/magic_links_controller_test.rb
```

RED: salida 1; 19 casos, 66 aserciones, tres fallos y cero errores.
Las dos solicitudes devolvieron `[200, 200]` en lugar de `[200, 401]`.
El segundo objeto y el objeto vencido devolvieron un enlace en lugar de `nil`.
Log local: `.context/handy-935-red.log`.

GREEN: mismo entorno y selección, con `mise exec -- bin/rails test` en este
checkout, sin `ruby -C`: salida 0; 19 casos, 73 aserciones, cero fallos,
errores u omisiones. Una solicitud obtiene un token; la otra devuelve 401 y
`Try another code.`, sin token ni cookie de sesión. El conteo de sesiones se
lee sin caché para observar las escrituras de las otras conexiones.
Log local: `.context/handy-935-green.log`.

Versiones idénticas en RED y GREEN (SHA-256):

| Archivo | SHA-256 |
|---|---|
| `test/models/magic_link_test.rb` | `b27cd9882f4783dfced84a9e78b5029c8d0fa08297a5b7723a813ba8226ee055` |
| `test/controllers/sessions/magic_link_concurrency_test.rb` | `b66112ad9a45a5d4ea16317562c69fe96e32929ab02d2663cd9e9309a05dec54` |

RuboCop sobre los tres archivos Ruby modificados: salida 0, sin infracciones.

Suite completa: mismo entorno con `PARALLEL_WORKERS=4` y
`mise exec -- bin/rails test`: salida 0; 1868 casos, 7387 aserciones,
cero fallos, cero errores y seis omisiones. Log local:
`.context/handy-935-suite.log`.

## Operación y límites

El DELETE incluye id y vigencia y sólo devuelve el objeto si afecta una fila.
No necesita una transacción de lectura ni un bloqueo de fila. Sigue el
contrato existente de `Identity::Transfer#consume`. El único consumidor de
`MagicLink.consume` es el controlador de acceso; sigue comprobando el correo
antes de crear la sesión. No hay callbacks de destrucción en `MagicLink`.

No verificado: MySQL, modo SaaS ni un despliegue real. La prueba de concurrencia
usa SQLite y dos clientes HTTP reales dentro del proceso de pruebas.
