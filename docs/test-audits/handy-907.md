# Sincronización con basecamp/fizzy `e2181a7c7`: lectura de ZIP

El merge de upstream `e2181a7c78482981ba6a7f1a0fbe3bcd187a6d3b` (los 22
commits hasta `ea3cc44be`, más `e2181a7c7`, que sólo cambia scripts SaaS) sobre
`993f5307e9c5b3efe3229fc48300e5888f82b144` trae una segunda protección de
importación (PR #3113): lectura en memoria hasta 4 MB por entrada
(`MAX_BUFFERED_ENTRY_SIZE`), presupuesto total de 100 veces el tamaño del
archivo (mínimo 64 MB), extracción en trozos de 64 KB comprimidos, parada en un
deflate truncado y lotes de importación de hasta 16 MB.

Nuestra protección de Handy #782 y #829 queda igual: `ZipFile::Limits` valida el
directorio central antes de extraer y `ZipFile::Reader::Structure` lee sólo el
directorio. Resolución:

- `ZipFile::Reader` y `ZipFile::Reader::IO` son los de upstream, más nuestro
  `initialize(io, limits:)`, `read_structure` y `uncompressed_size`.
- `EntryTooLargeError` y `ArchiveTooLargeError` quedan como en upstream
  (`InvalidFileError`). No hace falta que hereden de `LimitExceededError`:
  `Account::Import#mark_as_failed` purga filas y archivos con cualquier fallo
  (Handy #954). Con ellas, «process stops a stored file … and discards the
  partial import» pasa sin cambio de lógica.
- El filtro de parámetros de passkey (#778) pasa a `config/application.rb`
  porque upstream eliminó `config/initializers/filter_parameter_logging.rb`.

## Pruebas cambiadas

| Archivo | Caso | Cambio | Razón |
|---|---|---|---|
| `models/account/import_test.rb` | check … record entry inflates past the size limit (upstream) | espera `LimitExceededError` | `Limits` rechaza la relación de compresión con `LimitExceededError` antes del tope de 4 MB; el contrato (`invalid_export`) sigue comprobado y el tope de 4 MB lo prueban los casos de `zip_file_test.rb` |
| `models/account/import_test.rb` | process stops a stored file … (#782) | texto del mensaje | `IO` de upstream dice `expands past the N bytes it declares` |
| `models/zip_file_test.rb` | reader io stops an entry that expands beyond its declared size (#782) | texto del mensaje | la lectura en memoria usa ahora `extract_within` |
| `models/webhook/delivery_test.rb` | connects to the pinned IP address even when a proxy is configured (upstream) | URL `https://` y puerto 443; también fija y restaura `https_proxy` | el fork exige HTTPS (Handy #958): con `http://` la entrega se bloquea antes de conectar y el caso no observa el proxy |
| `models/webhook/tls_test.rb` | los tres casos (Handy, `087f76c60`) | `Net::HTTP.expects(:new)` con el tercer argumento `nil` | upstream `f22d19eb6` pasa `nil` como proxy; sin el cambio, mocha no reconoce la llamada y la prueba no llega al TLS |

## Prueba retirada

| Campo | Evidencia |
|---|---|
| Identidad y dueño | `fizzy-custom`, `test/models/zip_file_test.rb`, «reader io inflates a deflated entry in bounded chunks» (`637bf8bfb`, #782); `ZipFile::Reader::IO#read` |
| Fallo detectable | Pedía `read(5 MB)` de 2 MB aleatorios y exigía menos de 1 MB: detectaba un `read` que inflaba todo `length` comprimido de una vez |
| Consumidores | `IO#read` lo usan `Reader#read` con bloque, el upload de Active Storage y las pruebas de `zip_file_test.rb` |
| Cobertura restante | upstream «reader io returns no more than the length asked for from a deflated entry», «streams a deflated entry intact in small reads», «stops at a truncated deflate stream» y los dos casos de `ArchiveTooLargeError`; comando de la sección siguiente |
| Historia | La IO de #782 devolvía un trozo corto; la de upstream llena un búfer hasta `length` en trozos de 64 KB comprimidos (`slice_size`). Con la IO de upstream el caso falla porque `read` devuelve los 2 MB pedidos, que es lo correcto |
| Riesgo | Ninguna prueba observa directamente el troceo interno de 64 KB comprimidos; lo acotan el presupuesto por archivo y `length`. No se agrega prueba: observarlo exige acoplarse a variables internas |
| Validación | Antes del retiro: 1 fallo (`Expected 2097152 to be < 1048576`); después: 0 fallos |
| Decisión | Retirar |

## Pruebas importadas de upstream

Upstream integrado: `e2181a7c78482981ba6a7f1a0fbe3bcd187a6d3b`; base de
upstream anterior: `d157d2c6816ddfabf6ee09939e2a736e518ad0b2`. No se cambia
ninguna prueba importada, salvo las tres de la sección anterior.

### Contratos

**Dueño único de la cuenta** (`users_controller_test.rb`, 5 casos;
`user/role_test.rb`, «sole owner?»; upstream `7e4b5e553`, `0346930a9`).
- *Contrato:* el único dueño activo no se puede desactivar (HTML y JSON); con
  otro dueño activo sí puede; admin y miembro pueden. Dueños:
  `UsersController#destroy`, `User::Role#sole_owner?`. Frontera: HTTP.
- *Regresión:* quitar el guard deja la cuenta sin dueño; contar un dueño
  inactivo como segundo dueño permite lo mismo.
- *Cobertura:* las pruebas anteriores sólo cubrían desactivar a otro usuario.
  Los tres casos permitidos protegen contra un guard demasiado amplio.
- *Seam:* `sole_owner?` es productivo (lo usa el controlador).

**Proxy y dirección fijada** (`webhook/delivery_test.rb`,
`web_push/persistent_request_test.rb`, `push/subscription_test.rb`; upstream
`f22d19eb6`, `9839d5224`, `927a57878`).
- *Contrato:* con `http_proxy` definido, el webhook y el web push conectan a la
  IP comprobada, no al proxy; sin IP comprobada, o con un host que ahora
  resuelve a una IP privada, no hay envío. Dueños: `Webhook::Delivery`,
  `config/initializers/web_push.rb`, `WebPush::Notification`. Frontera:
  `TCPSocket.open` y WebMock.
- *Regresión:* `Net::HTTP` usa el proxy del entorno y el proxy resuelve otra
  vez el nombre, lo que evita la protección SSRF.
- *Cobertura:* las pruebas anteriores fijaban la IP sin proxy en el entorno.
- *Seam:* ninguno nuevo; el entorno se restaura en cada caso.

**Lectura de ZIP de upstream** (`zip_file_test.rb`, 12 casos nuevos;
`account/import_test.rb`, «check … inflates past the size limit»;
`account/data_import_job_test.rb`, «discards the job …»; upstream `744fedbfe`
a `0f7d99f76`).
- *Contrato:* una lectura en memoria se detiene en 4 MB; una entrada se detiene
  en su tamaño declarado; `read(n)` devuelve como máximo `n`; un deflate
  truncado termina; el total leído se limita según el tamaño del archivo,
  también si un consumidor envuelve el error; el job descarta la importación.
  Dueños: `ZipFile::Reader`, `ZipFile::Reader::IO`, `Account::DataImportJob`.
- *Regresión:* leer sin tope infla gigabytes en el worker de jobs; confiar en
  el tamaño declarado al subir a S3.
- *Cobertura:* nuestros casos de #782 y #829 cubren el directorio central y el
  tamaño declarado, no el tope en memoria ni el presupuesto por archivo.
  Solapan (y pasan en la base): «understates an entry's size», «expands past
  its declared size», «streamed entry expands past its declared size» y el caso
  del job; se conservan porque fijan la clase de error nueva.
- *Seam:* `ZipFile::Reader#size` lo usa `RecordSet#batches_of`.
  `understate_declared_size` es un helper privado de `zip_file_test.rb`.

**Lotes de importación y usuarios de la exportación**
(`record_set_test.rb`, 2 casos; upstream `dec47a32f`, `61e1012c8`, #3111).
- *Contrato:* un lote termina al sumar 16 MB; un registro cuyo autor no es un
  usuario de la exportación se rechaza. Dueño: `RecordSet`.
- *Regresión:* 100 cuerpos de 4 MB en un lote; un autor externo a la cuenta.
- *Cobertura:* antes sólo se comprobaba el lote de 100 entradas.
- *Seam:* ninguno nuevo.

**Desactivación automática** (`card/entropic_test.rb`, 1 caso; `0e718f369`,
`6aebc0cea`).
- *Contrato:* una tarjeta que falla no detiene el barrido; el job falla al
  final con `AutoPostponeError`. Dueño: `Card::Entropic`.
- *Regresión:* el primer error detiene todas las tarjetas siguientes.
- *Cobertura:* antes no había caso con una tarjeta que falla.
- *Seam:* ninguno.

**HotCell** (`saas/test/hotcell-check-test`; `hotcell_accessory_test.rb`,
«HOTCELL_IMAGE overrides the pinned image»; upstream `e3de6eb27`).
- *Contrato:* el check detecta una celda detenida y reinicia un rollback con el
  pin de su commit; `HOTCELL_IMAGE` sustituye la imagen fijada en
  `saas/config/deploy.yml`. Frontera: comandos registrados por stubs; Kamal.
- *Regresión:* una celda detenida se toma como sana; un rollback reinicia con
  el pin del árbol.
- *Cobertura:* los escenarios anteriores no tenían celdas detenidas ni
  `--version`.
- *Seam:* `HOTCELL_IMAGE` es productivo (lo usa `saas/hotcell/bin/check`).

### RED en la base

Exportación aislada de `993f5307e9c5b3efe3229fc48300e5888f82b144` (el fork
antes del merge, primer padre del merge) con los diez archivos de prueba del merge
copiados encima. Preparación, desde `fizzy-custom/` con el merge en el árbol:

```bash
FILES="test/controllers/users_controller_test.rb test/jobs/account/data_import_job_test.rb \
  test/lib/web_push/persistent_request_test.rb test/models/account/data_transfer/record_set_test.rb \
  test/models/account/import_test.rb test/models/card/entropic_test.rb test/models/push/subscription_test.rb \
  test/models/user/role_test.rb test/models/webhook/delivery_test.rb test/models/zip_file_test.rb"
BASE=../.context/handy-907-base
rm -rf $BASE && mkdir -p $BASE && git archive 993f5307e9c5b3efe3229fc48300e5888f82b144 | tar -x -C $BASE
for f in $FILES saas/test/hotcell-check-test; do cp "$f" "$BASE/$f"; done

run() {
  env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
    -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
    SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
    mise exec -- "$@"
}
```

RED sin shim:

```bash
(cd $BASE && run ./bin/rails test $FILES)
```

Primera ejecución: salida 1; 190 casos, 10 fallos, 14 errores. Los errores son
`NameError`/`NoMethodError` de nombres nuevos, que no son RED válidos. Por eso
se repitió con un shim cargado sólo en la exportación, después de
`config/environment`, que define nombres y no comportamiento:
`EntryTooLargeError` y `ArchiveTooLargeError` como alias de
`LimitExceededError`, `MAX_BUFFERED_ENTRY_SIZE = 4 MB`, `IMPORT_BATCH_BYTES =
16 MB`, `Reader#size` (lee el tamaño declarado) y `AutoPostponeError`.

El shim se guarda en `../.context/handy-907-red-shim.rb` y se carga en la
exportación con una línea después de `require_relative "../config/environment"`:

```bash
sed -i '2a require File.expand_path("../../handy-907-red-shim.rb", __dir__)' $BASE/test/test_helper.rb
(cd $BASE && run ./bin/rails test $FILES)
```

Contenido del shim:

```ruby
# RED shim for handy-907: names only, no behaviour. Loaded by the base export's test_helper.
begin
  ZipFile.const_set(:EntryTooLargeError, ZipFile::LimitExceededError) unless ZipFile.const_defined?(:EntryTooLargeError, false)
  ZipFile.const_set(:ArchiveTooLargeError, ZipFile::LimitExceededError) unless ZipFile.const_defined?(:ArchiveTooLargeError, false)
  ZipFile::Reader.const_set(:MAX_BUFFERED_ENTRY_SIZE, 4.megabytes) unless ZipFile::Reader.const_defined?(:MAX_BUFFERED_ENTRY_SIZE, false)
  ZipFile::Reader.class_eval do
    def size(path) = @reader.find { |e| e.filename == path }.uncompressed_size
  end unless ZipFile::Reader.method_defined?(:size)
  Account::DataTransfer::RecordSet.const_set(:IMPORT_BATCH_BYTES, 16.megabytes) unless Account::DataTransfer::RecordSet.const_defined?(:IMPORT_BATCH_BYTES, false)
  Card::Entropic.const_set(:AutoPostponeError, Class.new(StandardError)) unless Card::Entropic.const_defined?(:AutoPostponeError, false)
end
```

Segunda ejecución: salida 1; 190 casos, 16 fallos, 1 error. Cada fallo es la
causa del contrato: dueño único desactivado (`User.active.count` cambia en -1,
HTML y JSON); conexión a `proxy.internal:3128` (webhook y web push); POST
enviado sin IP comprobada y con IP privada; el lote no termina en 16 MB
(`[3, 2]` esperado); autor externo aceptado; el barrido no lanza
`AutoPostponeError`; entrada de 4 MB + 1 leída sin error; `read(1024)` devuelve
más; presupuesto por archivo no aplicado (en lectura y antes de transmitir);
error envuelto por el consumidor. El error restante es «sole owner?»: el método
es API nueva; su contrato tiene RED en los dos casos HTTP.

Casos que pasan en la base, con la razón: «owner can deactivate … another owner
remains», «admin/member can deactivate themself» (protegen contra un guard
demasiado amplio); «reads an entry at the size limit», «streams an entry over
the size limit when given a block», «streams a deflated entry intact in small
reads» (protegen lo que el tope no debe romper); «stops at a truncated deflate
stream», «understates an entry's size», «expands past its declared size»,
«streamed entry expands past its declared size», «discards the job …» y
«check … inflates past the size limit» (#782 y #829 ya los detectaban).

GREEN en `fizzy-custom/`, `run bin/rails test $FILES`: salida 0; 190 casos,
764 aserciones, sin fallos.

`(cd $BASE && bash saas/test/hotcell-check-test)`: salida 1, 21 escenarios
correctos y 20 fallos (la base pide `{{.Config.Image}}` sin el estado, no ve la
celda detenida y no usa el pin de `--version`). `bash saas/test/hotcell-check-test` en `fizzy-custom/`: salida 0,
41 correctos.

### Excepción RED explícita de SaaS

`hotcell_accessory_test.rb` no carga sin la gema privada `fizzy-saas`
(`Gem::MissingSpecError`), en la base y en el merge, igual que en
`docs/test-audits/handy-610.md`. Ese fallo no es RED. Validación alternativa:
lectura del ERB de `saas/config/deploy.yml` y el escenario de rollback de
`hotcell-check-test`. No verificado: la configuración Kamal SaaS completa.

## Validación

```bash
run bin/rails test test/models/account test/jobs/account test/models/zip_file_test.rb \
  test/models/zip_file test/models/webhook
run bin/rails test
run bin/rails test:system
```

Salida 0 en los tres: 253 casos del área; 2092 casos de la suite (6 omitidos);
61 casos de navegador. Sin fallos ni errores.

Una segunda corrida de navegador tuvo 1 error de tiempo en
`ai_suggestion_test.rb:180` (`wait_for_request`), con carga media de 28 en la
máquina. El merge no toca sugerencias, JavaScript ni Cable. Con carga baja, el
archivo pasó 4 de 4 veces en el merge y 4 de 4 en la base.
