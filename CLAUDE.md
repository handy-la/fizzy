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

## UUID primary keys

All tables use UUIDv7 keys, base36-encoded to 25 characters. Fixture UUIDs
are generated to sort older than any runtime record, so `.first`/`.last`
stay deterministic in tests — don't "fix" ordering by comparing insertion
order to id order.

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

## Imports and exports

Data transfer between instances (`app/models/account/data_transfer/`,
`app/models/zip_file`) must work against both local and S3 storage, and
archives can exceed hundreds of gigabytes — stream, never buffer a whole
file.

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
las filas y archivos importados (`Manifest#discard_records`).
Evidencia: `docs/test-audits/handy-782.md`.

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

## Reintentos de webhooks

Una entrega pendiente conserva el cuerpo y las cabeceras del primer intento en
`request` (texto largo, como los cuerpos de ActionText); los reintentos usan esos mismos bytes. Dédalo deduplica por el `id`
JSON del evento, no por una cabecera nueva. La espera crece de 1 a 30 minutos,
durante 24 horas desde el primer intento. Los 4xx y los destinos privados son
fallos terminales. La cola `webhooks` serializa por receptor; cada entrega espera
sus predecesoras pendientes de la misma tarjeta (incluidos sus comentarios).
Un envío en progreso sin actualizarse por cinco minutos vuelve a la cola;
un barrido cada minuto también lo recupera sin esperar otro evento. Antes del
HTTP se guardan los bytes del mensaje. Evidencia y límites: `docs/test-audits/handy-545.md`.

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

## Passkeys: un challenge autentica una vez

El challenge sigue firmado y sin estado, pero `ActionPack::Passkey#authenticate`
lo consume en `action_pack_passkey_consumed_challenges` (índice único) en la
misma transacción que avanza `sign_count` con un `UPDATE` condicionado. No
vuelvas a `update!`: con contador cero, sólo el consumo detiene un replay. El
mensaje firmado es `<nonce>:<vence en>`; `cleanup` borra una fila sólo cuando
su challenge ya venció, y por eso `consume!` comprueba el vencimiento después
de insertar: una petición detenida hasta después de la limpieza no reutiliza
el challenge. Los campos WebAuthn y `passkey.id` se filtran en
`filter_parameter_logging.rb`. Evidencia: `docs/test-audits/handy-778.md`.

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
La identidad de una reserva de borrado es opcional: una importación conserva
metadata del autor, pero ese autor puede no existir aquí. Evidencia y límites:
`docs/test-audits/handy-779.md`.
