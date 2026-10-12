# Fizzy

Responde únicamente en español técnico simplificado (equivalente al estándar ASD-STE100).

Fizzy is a kanban-style project management and issue tracker: cards move
across columns on boards, with comments, mentions, and assignments.

These instructions are defaults with reasons, not law — when the code in
front of you disagrees, take the better path and flag the conflict; invariants
(data loss, security, CI gates) are surfaced, not overridden. Attack your own
diff before calling it done.

## Deploy

Default branch: `main`

Self-hosted deploys run Kamal against `config/deploy.yml` — see `docs/kamal-deployment.md`.

## Poly-repo shells

The Handy poly-repo may enter this checkout with RVM already active. `bin/setup`
clears inherited Ruby/Bundler variables and `bin/dev` re-enters through the Ruby
pinned by mise. Do not remove that boundary: mixing RVM native extensions with
the mise Ruby fails later as an unrelated OpenSSL or psych activation error.

Run tests through `mise exec` too, after clearing inherited Ruby/Bundler
variables. For `test/dev-port-test`, select Ruby before entering its temporary
sandboxes: a Ruby shim resolves configuration from the sandbox's directory,
which can change the selected Ruby or fail its trust check. Evidence and commands:
`docs/test-audits/handy-610.md`.

## SaaS mode

For local agent work, `tmp/saas.txt` is the checkout-level SaaS switch used by `bin/setup`. When present, read `saas/AGENTS.md` before continuing. Otherwise, do not apply its instructions.

## Multi-tenancy is URL-based

Accounts get a decimal `external_account_id` URL prefix (`/{account_id}/boards/...`).
`AccountSlug::Extractor` middleware sets `Current.account` and moves the slug
from `PATH_INFO` to `SCRIPT_NAME`, so Rails behaves as if mounted at that
path — route helpers and request specs that assume a bare root will mislead
you. Domain records are account-scoped; identity, session, and authentication
records are the global exceptions. Background jobs serialize and restore
`Current.account` themselves.

A global `Identity` (email-based) can hold `Users` in multiple accounts, so
an email address is not a single account membership. Board access is per-user
`Access` records.

Los borradores sólo son visibles para su creador o un administrador con acceso
al tablero. Usa `User#accessible_cards`, que aplica `Card.visible_to(user)`;
no uses `board.cards` para resolver una tarjeta por número recibido. El filtro
usa el dueño de la asociación, no `Current.user`, porque también se usa en
exportaciones y Cable. Política y evidencia: `docs/test-audits/handy-938.md`.

La revocación de `Access` borra las notificaciones del tablero en su misma
transacción; el job de limpieza sigue como defensa secundaria. Filtra las
colecciones con `Notification.accessible` y vuelve a comprobar `accessible?`
antes de renderizar un aviso o enviarlo por push. La comprobación consulta
el acceso del destinatario en la base: una asociación o un fragmento cargado
antes de revocar no autoriza la entrega. Un push en cola cuyo aviso fue borrado
se descarta al deserializar. Evidencia y límites: `docs/test-audits/handy-924.md`.

## UUID primary keys

All tables use UUIDv7 keys, base36-encoded to 25 characters. Fixture UUIDs
are generated to sort older than any runtime record, so `.first`/`.last`
stay deterministic in tests — don't "fix" ordering by comparing insertion
order to id order.

Los UUIDv7 de ejecución pueden invertir el orden dentro del mismo milisegundo.
Una prueba de cursor debe usar IDs con orden explícito. Este tipo `Uuid` espera
25 caracteres base36; `cast` no convierte un UUID con guiones. Usa datos base36
o `ActiveRecord::Type::Uuid.hex_to_base36` sobre los dígitos hexadecimales.
Pasar UUIDs con guiones puede truncarlos al mismo valor al guardar.

## Search is sharded on MySQL, single-index on SQLite

Full-text search runs in the database through ActiveSearch, not Elasticsearch.
On MySQL it is sharded 16 ways by CRC32 of the account ID, through our own
`ActiveSearch::StoreAdapters::MysqlSharded`; on SQLite it is a single FTS5 index
through the gem's `sqlite` adapter. Don't assume the sharded shape when working
under SQLite. Index schema, adapter registration and the document class are all
in `config/search.rb`.

Models join the index with `has_search`, and the store adapter owns every
read and write. Don't reach for a search table directly — go through
`ActiveSearch.index(:searchable)`.

El `board_id` de un comentario en el índice puede quedar atrasado al mover su
tarjeta. `User#search` autoriza por `card_id` con una subconsulta de
`accessible_cards`, antes de paginar o hidratar. No uses el tablero del índice
como permiso: el reindex asíncrono sólo mantiene el índice.
Evidencia: `docs/test-audits/handy-939.md`.

## Imports and exports

La admisión de exportaciones usa `Export.start_for`: el UPDATE del principal
debe ocurrir antes del conteo, en la misma transacción que crea la fila.
`with_lock` por sí solo no toma un bloqueo de escritura en SQLite. El límite
diario cuenta todos los estados; el cupo de trabajo cuenta pending y processing
sin fecha. Completed y failed liberan ese cupo, pero no el límite diario.
`DataExportJob` comparte un lease de 24 horas por cuenta o usuario, según el
tipo de exportación. Evidencia y límites: `docs/test-audits/handy-937.md`.

Data transfer between instances (`app/models/account/data_transfer/`,
`app/models/zip_file`) must work against both local and S3 storage, and
exports can exceed hundreds of gigabytes — stream, never buffer a whole
file. Imports have the admission limits described below.

En modo de cuenta única, `Account.create_with_owner` es la operación que
controla la admisión. Crea el tenant remoto dentro de su bloque de atributos:
crearlo antes permite recursos remotos cuando el registro se rechaza.
`Account::SignupLock` toma un bloqueo de escritura antes de consultar las
cuentas; bloquear una cuenta existente no protege el primer registro.
El seed de desarrollo activa varias cuentas sólo en su proceso y restaura la
configuración al terminar. No agregues una excepción al registro público.
Evidencia y límites: `docs/test-audits/handy-781.md`.

Una importación abre su ZIP con `Account::Import::LIMITS`: `ZipFile::Limits`
rechaza el directorio central (entradas, bytes por entrada, límite menor para
JSON, total, relación de compresión) antes de extraer, y `ZipFile::Reader::IO`
detiene una entrada cuyos bytes reales pasan su tamaño declarado. Lee las
entradas sólo con `ZipFile::Reader#read`: el extractor de ZipKit directo omite
ese contador e infla un trozo completo de una vez. Un límite en `process` borra
las filas y archivos importados (`Manifest#delete_files` y después
`Manifest#discard_records`, que sólo borra filas).
Evidencia: `docs/test-audits/handy-782.md`.

`Account::Import.start` usa `Account::Import::Admission`: un cupo activo y tres
intentos por identidad en 24 horas, incluidos los inválidos. Su UPDATE de
identidad ocurre antes de leer; la reserva toma después el lock de cuenta
compartido con cargas directas. El cargo incluye ZIP y expansión en Disk y S3.
El máximo comprimido es 100 MiB; la expansión y el presupuesto activo por
identidad son 1 GiB; el máximo es 10.000 registros. Capacidad desconocida
rechaza la carga. La reserva no vence mientras haya datos sin borrar.
Al terminar, la conciliación y el traspaso a cargo de adjuntos o reservas de
blobs sin adjunto ocurren bajo el mismo lock. Los errores terminales purgan
ZIP y datos parciales; primero se borra el objeto, después se libera su cargo.
La purga de una importación fallida borra los objetos antes del lock de cuenta:
en SQLite ese lock detiene a todos los escritores. `cleanup` aísla cada
importación y sigue con las demás. Evidencia: `docs/test-audits/handy-954.md`.
No uses `purge_later` para esta limpieza. Los metadatos de cuota importados se
eliminan; el servidor crea filas de reserva con los bytes comprobados. Evidencia: `docs/test-audits/handy-943.md`.

Un proceso detenido entre `claim` y el import, o una cuenta destruida, deja la
admisión sin terminar y la identidad recibe 429 para siempre. La recuperación
es `bin/rails imports:recover_admissions EMAIL=…` (`Admission#recover`). No
liberes admisiones por fecha: rechaza si es reciente, si hay import activo o
si la cuenta tiene blobs. Un import fallido sigue por `purge_failed_files`.
Evidencia: `docs/test-audits/handy-953.md`.

`ZipKit::FileReader#read_zip_structure` lee todo el tramo final y confía en el
tamaño del EOCD ZIP64. Usa `ZipFile::Reader::Structure`: valida los metadatos
antes de crear entradas y lee sólo `cdir_size`. `ZipFile::Limits` limita el
directorio a 16 MiB por defecto. Un tamaño declarado incorrecto se rechaza;
no agregues una lectura hasta EOF como recuperación.
Evidencia: `docs/test-audits/handy-829.md`.

`Account::DataImportJob` permite tres reanudaciones y sólo los errores de
`Account::Import::TRANSIENT_ERRORS`, además de una interrupción del worker.
Un paso reanudado puede fallar sin avanzar: captura esos errores en `perform`,
porque `Continuable` no los reintenta por sí solo. JSON debe ser un objeto
con UTF-8 válido; el estado fallido y su correo se guardan sólo al terminar.
Evidencia: `docs/test-audits/handy-932.md`.

`Account::Import` admite 20.000 entradas y un directorio de 4 MiB como máximo,
antes de crear entradas. El lector conserva un índice por nombre para evitar
recorrer toda la lista en cada lectura. `Account::Import.start` reserva una sola
importación pendiente o en curso por identidad global bajo un lock de escritura;
el controlador debe usar esa operación antes de crear cuenta, blob o trabajo.
`DataImportJob` también serializa por identidad en Solid Queue, para incluir
reintentos y trabajos admitidos antes de esta política.
Una consulta por cuenta no protege una identidad que crea otra cuenta.
Evidencia y presupuesto medido: `docs/test-audits/handy-936.md`.

## Medios externos y saneado de Action Text

Action Text vuelve a sanear el HTML que generan los partials. Su lista por
omisión quita `rel` y `target`: un enlace seguro en el partial pierde su
protección al mostrar una tarjeta. Conserva esos atributos en el initializer
de saneado y prueba `ActionText::Content#to_s`, además de la vista directa.
El scrubber fuerza `noopener noreferrer` cuando un enlace aporta `rel` o
`target`, y sólo conserva `target=_blank`. Asigna las listas de etiquetas y
atributos al scrubber: al pasarlo, Rails deja de usar las opciones del filtro.
Los medios remotos requieren una acción explícita; `img-src` y `media-src`
no deben permitir todo HTTPS. Para S3 o un CDN, autoriza su origen exacto.
Evidencia y límites: `docs/test-audits/handy-922.md`.

## Coding style

Before editing or reviewing code, read STYLE.md.

## Aviso de siguiente tarjeta

Captura la etapa antes de mover o cerrar: una tarjeta cerrada conserva
`column_id`, pero ya pertenece a Done. El aviso se actualiza fuera del
contenedor de tarjeta para que Turbo Stream pueda mostrarlo después de Done.
Una transición por HTML desde el selector debe usar `turbo_frame: "_top"`;
de otro modo, Turbo extrae sólo el frame de etapas y pierde el aviso.
El contenedor lleva un id propio de la tarjeta. Su controlador conserva el
aviso sólo cuando un morph del mismo contenedor llega vacío: el refresco de
Cable no debe quitarlo, pero otro movimiento debe sustituirlo. No uses
`data-turbo-permanent` en el aviso: conserva texto anterior o duplica avisos
al mover de nuevo. `data-turbo-temporary` evita guardarlo al volver por el
historial; el contenedor de destino del stream sí permanece.
Evidencia: `docs/test-audits/handy-628.md`.

Una prueba de sistema que cambia el tamaño de la ventana debe restaurarlo
en `ensure`. Capybara reutiliza el navegador: dejarlo en tamaño móvil oculta
elementos y rompe pruebas de navegación o notificaciones posteriores.

Una prueba sin transacciones debe borrar en `teardown` los registros que crea
en tablas sin fixtures. `fixtures :all` sólo limpia tablas con fixtures:
dejar una sugerencia pendiente puede consumir cupos y hacer que un job de
una prueba posterior genere para la tarjeta anterior. Evidencia y limpieza:
`docs/test-audits/handy-934.md`.

## Pegado en pruebas de sistema

La barra flotante de una tarjeta puede cubrir el centro de `lexxy-editor`.
Para pegar, haz clic cerca de la esquina superior del campo `contenteditable`,
tras dejarlo completo dentro de la ventana. Comprueba su foco y envía el evento
a ese campo. Un clic en el contenedor
seguido de un pegado a `document.activeElement` puede enviarlo a `BODY`.
Evidencia: `docs/test-audits/handy-568.md`.

## Fireworks y RubyLLM

RubyLLM 2.0 usa Responses como protocolo OpenAI predeterminado. Para Fireworks,
crea el chat con `provider: :openai, protocol: :chat_completions,
assume_model_exists: true`: el router de Fireworks no está en el registro de
modelos de OpenAI. Las sugerencias son texto para editar; nunca publican un
comentario por sí mismas. `Card::Suggestion` conserva todos los comentarios;
un contexto demasiado grande se rechaza, nunca se recorta sin avisar.

Las sugerencias se generan en `Card::SuggestionJob`, en la cola exclusiva
`ai_suggestions`. Nunca esperes al proveedor en una petición web. La lista de
colas normales en `config/queue.yml` es explícita: al agregar una cola normal,
agrégala allí; `*` permitiría que sus workers esperen también al proveedor.
El evento `lexxy:change` es sintético incluso al escribir: sólo un `beforeinput`
o un `paste` real autoriza el debounce del título (Lexical cancela el pegado
antes del `beforeinput`). En comentarios, un foco programático
puede tener `isTrusted`: exige también la intención real de puntero o Tab.
En un celular el foco llega tras esa intención; lo autoriza el `click` del toque.

La admisión de IA cuenta solicitudes `pending` y `running` bajo
`Card::SuggestionQueue`: una por usuario, dos por cuenta y cuatro globales.
Los jobs sólo avisan al planificador global, que da turnos por cuenta; no
vuelvas a encolar directamente una llamada por tarjeta. Las reservas de gasto
viven fuera de la fila reutilizable de solicitud. Contrato y recuperación:
`docs/ai-suggestions.md`; evidencia: `docs/test-audits/handy-934.md`.

## Reintentos de webhooks

Una entrega pendiente conserva el cuerpo y la firma del evento del primer intento en
`request` (texto largo, como los cuerpos de ActionText); los reintentos usan esos mismos bytes. Dédalo deduplica por el `id`
JSON del evento, no por una cabecera nueva. La espera crece de 1 a 30 minutos,
durante 24 horas desde el primer intento. Los 4xx y los destinos privados son
fallos terminales. Los límites son 5 webhooks por tablero, 20 por cuenta y 10
peticiones de creación por minuto por cuenta. Inactivos también cuentan. La admisión y la reserva de
reintento toman un UPDATE de cuenta antes de leer, dentro de su transacción.

`Webhook::Dispatch` conserva un único aviso global y alterna cuentas; sólo su
job hace HTTP en la cola exclusiva `webhook_dispatch`. No encoles jobs por
entrega ni por sucesor bloqueado. Conserva el orden por tarjeta y limita a un
HTTP por cuenta, con un máximo global de uno. La cuota de 100 pendientes/en
progreso por cuenta descarta las entregas nuevas al llenarse; el evento se
conserva. Hay hasta 8 intentos por entrega y 60 reintentos por hora por cuenta.
El barrido por minuto recupera leases de cinco minutos y despierta reintentos
vencidos. `webhooks` queda separada para drenar jobs antiguos. Contrato y
límites: `docs/webhook-resources.md`; evidencia: `docs/test-audits/handy-942.md`.

Los webhooks sólo aceptan HTTPS. La migración desactiva las URLs HTTP antiguas
sin convertirlas: el mismo destino puede no ofrecer TLS. Una entrega antigua
también debe rechazar HTTP antes de DNS y de `Net::HTTP`, aunque conserve
un mensaje para reintentar. Conserva `Net::HTTP.new(hostname, port)` e
`ipaddr` por separado para mantener SNI y verificación del certificado.
Pruebas y dependencia del receptor: `docs/test-audits/handy-941.md`.
Un destino HTTP heredado no pasa la validación: `deactivate` escribe sólo
`active` sin validar, y `activate` devuelve falso con el motivo para el usuario.
No uses `update!` ni `update_attribute` ahí. Evidencia: `docs/test-audits/handy-958.md`.

Cada intento renueva `X-Webhook-Timestamp` y firma `<fecha>.<cuerpo persistido>`
en `X-Webhook-Attempt-Signature` (ADR-0053 de Dédalo). La firma original del
cuerpo se conserva. No reutilices la fecha inicial: el receptor exige hasta
cinco minutos de antigüedad y 60 segundos hacia el futuro. La primera firma
de intento válida activa el rechazo de fechas sin firmar en el receptor;
volver a un emisor antiguo después de eso produce 401. Ambas firmas se
ocultan en el historial.

Las propuestas de comentario llegan por `CardSuggestionChannel`, privado por
usuario, cuenta y token. El canal vuelve a comprobar acceso al recuperar o
recibir una notificación; el broadcast no contiene texto. La huella del contexto
usa UTC con microsegundos: un hilo de Cable puede tener otra zona horaria y una
huella basada en `Time#to_s` descarta resultados válidos. El placeholder de Lexxy
se copia al editable interior al crearlo; hay que actualizar ambos atributos e
interceptar Enter en captura antes de Lexical. Guía y tiempos:
`docs/ai-suggestions.md`.

Una cancelación revoca las sugerencias dentro de su transacción y cierra Cable
en `after_create_commit`. Cierra por `account.users`, nunca por `Identity`: una
identidad puede tener otra cuenta activa. Recarga la cuenta antes de generar
o transmitir; una asociación cargada conserva el estado anterior. Contrato y
límites: `docs/ai-suggestions.md`; evidencia: `docs/test-audits/handy-783.md`.

Los controladores de Active Storage no incluyen `Authorization`: un control
de cuenta activa en `ensure_can_access_account` no los alcanza. Repite el
estado de cuenta y usuario en `lib/rails_ext/active_storage_authorization.rb`;
un blob público también exige que la cuenta del adjunto siga activa.
Evidencia: `docs/test-audits/handy-784.md`.

## Cuotas y envío push

`Push::Subscription.register_for` bloquea al usuario con UPDATE antes de leer
o sustituir destinos; `with_lock` solo no basta en SQLite. El navegador conserva
`client_id` en localStorage para sustituir tokens. El pool reserva presupuesto
por cuenta antes del DNS y reparte workers por turnos. Conserva el límite de
lectura para filas antiguas; `find_each` omite el orden de esa selección.
Política de descarte y evidencia: `docs/test-audits/handy-940.md`.

## Passkeys: un challenge autentica una vez

El challenge sigue firmado y sin estado, pero `ActionPack::Passkey#authenticate`
lo consume en `action_pack_passkey_consumed_challenges` (índice único) en la
misma transacción que avanza `sign_count` con un `UPDATE` condicionado. No
vuelvas a `update!`: con contador cero, sólo el consumo detiene un replay. El
mensaje firmado es `<nonce>:<user verification>:<vence en>`; `cleanup` borra una fila sólo cuando
su challenge ya venció, y por eso `consume!` comprueba el vencimiento después
de insertar: una petición detenida hasta después de la limpieza no reutiliza
el challenge. Los campos WebAuthn y `passkey.id` se filtran en
`filter_parameter_logging.rb`. Evidencia: `docs/test-audits/handy-778.md`.

El servidor exige UV por su cuenta: `userVerification` en las opciones es sólo
una petición al navegador. `ActionPack::Passkey` recalcula la política (valores
globales más el holder, leído después de encontrar la credencial) y la pasa a la
respuesta; ésta exige UV si esa política o la firmada en el challenge es
`required`. No llames a `PublicKeyCredential#authenticate` sin `user_verification:`.
Evidencia: `docs/test-audits/handy-945.md`.

## Cuota y borrado de cargas directas

Una carga directa reserva espacio antes de emitir la URL: máximo 100 MiB por
objeto, 20 cargas en curso por identidad global y 100 por cuenta durante la URL
y su margen. Los borradores retenidos ya no ocupan esos cupos después de esa
ventana, pero siguen consumiendo bytes. El servidor propio
limita cada cuenta a 10 GiB; SaaS usa `storage_limit`. La cuota usa el consumo
exacto, incluidas las reservas, bajo locks de identidad y cuenta, en ese orden.
Un UPDATE antes de leer obtiene el lock también en SQLite.

Los callbacks de adjuntos transfieren el cargo dentro de la transacción. Los
avatares cargados por esta vía también cuentan. Al quitar el último adjunto se
restaura la reserva: una URL PUT de S3 puede recrear el objeto tras borrarlo.
No liberes espacio ni pierdas la clave antes de borrar el objeto con éxito,
después del vencimiento de la URL (una hora) y su margen (una hora).
`Storage::CleanupUploadsJob` reintenta cada 15 minutos. Un archivo subido puede
seguir en un borrador local: conserva la reserva 30 días, separados de la URL.
Puede adjuntarse mientras exista. Si no hay objeto después de vencer la URL y
el margen, la limpieza libera la reserva. Los blobs antiguos sin reserva usan
la misma conservación de 30 días, que cubre sus URLs anteriores de 48 horas.
La fila de reserva emitida por el servidor se conserva al adjuntar; mientras
el blob tenga adjuntos, no suma bytes ni ocupa cupos de subida. El último
borrado sólo actualiza esa fila, sin crear otra desde metadata. Su identidad,
tamaño y fecha de emisión vienen de la reserva; la identidad debe tener un
usuario en la cuenta al emitirla. La importación reconstruye sólo metadata
portable y admite tanto el objeto JSON como la cadena JSON del export. Nunca
restaures quota_* ni reconstruyas reservas antiguas desde esos datos. Al completar
una importación, crea reservas locales con la identidad del importador y los
bytes comprobados. Conserva esas filas también para blobs adjuntos: los avatares
usan su presencia al conciliar y al desvincular. Sólo las filas sin adjuntos
suman bytes; crear campos quota_* en metadata rompe este contrato.
Evidencia y límites: `docs/test-audits/handy-779.md`,
`docs/test-audits/handy-931.md`, `docs/test-audits/handy-950.md` y
`docs/test-audits/handy-943.md`.

`pending` deriva su estado de los adjuntos reales con `NOT IN`. No lo
sustituyas por una marca «adjunta» en la fila: `detach` y `delete_all` quitan
adjuntos sin callbacks, y una marca desfasada baja el saldo y oculta la fila a
la limpieza. Su costo es lineal en las filas de la cuenta (unos 23 ms con
100 000). Medición y umbral: `docs/test-audits/handy-951.md`.

## Caché offline y cambios de sesión

El worker sólo guarda recursos estáticos públicos del mismo origen en
`fizzy-assets-v3`. Nunca guardes HTML autenticado, JSON ni adjuntos: una
revocación no se puede comprobar sin red. Conserva los controles HTTP de
credenciales de `OfflineCaching` y su after_action: `fresh_when` puede
reemplazar Cache-Control. Las solicitudes con Authorization o X-CSRF-Token
no se cachean; las claves de assets se construyen sólo con su URL pública.
Al activar, borra toda caché anterior excepto la pública actual. Vacía el
registro IndexedDB por transacción, también con conexiones antiguas abiertas.
Las transiciones de sesión y las respuestas sensibles esperan ese borrado;
la generación evita que una respuesta tardía restaure el ámbito anterior.
Turbo cambia de usuario sin ejecutar módulos otra vez: limpia en turbo:load
y pageshow. Una passkey usa form.submit(), que no emite submit.
No reactives el preloader de TurboOffline. Preserva la limpieza de snapshots
antes del logout y los controles de credenciales de Handy 925.
Evidencia: `docs/test-audits/handy-925.md` y `docs/test-audits/handy-927.md`.
