# Passkeys: un assertion autentica una sola vez

## Autoría antes de editar las pruebas

Base productiva: `e48df6ef274e7ccc63338f954e89f05982305c88` (incluye la
revisión auditada `25a93b13ec5a819fed72f956b64f7da424b5a852`).

- **Contrato:** un assertion WebAuthn válido crea una sola sesión. Su
  challenge se consume en la misma transacción que avanza el contador; un
  replay exacto falla aunque el autenticador deje el contador en cero. Dos
  assertions que compiten sobre el mismo contador lo avanzan una sola vez.
  Un challenge vencido o de registro no autentica. Los parámetros de las dos
  ceremonias (`id`, `client_data_json`, `authenticator_data`, `signature`,
  `attestation_object`) no llegan al log. Dueños: `ActionPack::Passkey#authenticate`,
  `ActionPack::Passkey::ConsumedChallenge` y
  `config/initializers/filter_parameter_logging.rb`. Fronteras: petición HTTP
  a `Sessions::PasskeysController` y `My::PasskeysController`
  (`request.filtered_parameters`, la fuente de la línea `Parameters:` del log),
  y el modelo con dos copias cargadas de la misma fila.
- **Regresión:** quitar `ConsumedChallenge.consume!` de `Passkey#authenticate`
  deja que el replay cree otra sesión; volver a `update!` en lugar del
  `update_all` condicionado deja que dos assertions con contador viejo
  autentiquen; quitar los campos del filtro los escribe en el log; quitar el
  vencimiento del mensaje firmado deja filas sin `expires_at` que `cleanup`
  nunca borra.
- **Cobertura:** `passkey_test.rb` y `sessions/passkeys_controller_test.rb`
  probaban un solo uso por challenge y nunca repetían el POST. Ninguna prueba
  leía los parámetros filtrados. `my/passkey_challenges_controller_test.rb`
  prueba el vencimiento sólo con el verificador, no con `authenticate`. Los
  casos nuevos amplían esos archivos. Vencido y de otro propósito ya pasaban en
  la base: son cobertura del contrato que pide la tarjeta, no regresiones.
- **Seam:** ninguno de prueba. `PublicKeyCredential#authenticate` ahora devuelve
  su `AssertionResponse`, y `Response#verified_challenge` /
  `#challenge_expires_at` exponen el challenge verificado; el consumidor
  productivo es `ActionPack::Passkey#authenticate`.
- **Pruebas modificadas:** «generates signed challenge containing nonce» en
  `request_options_test.rb` y `creation_options_test.rb`. El mensaje firmado
  pasó de `<nonce>` a `<nonce>:<vence en, epoch>`; la prueba conserva el nonce
  de 32 bytes y ahora comprueba también el vencimiento.

Casos nuevos: replay exacto con contador cero (HTTP, otro cliente sin
cookies); replay desde dos copias cargadas; contador viejo en carrera; un
assertion fallido no consume su challenge; challenge vencido; challenge de
registro; `cleanup` sólo borra challenges vencidos; filtro de parámetros de
assertion y de attestation.

## Concurrencia

La atomicidad viene del índice único de
`action_pack_passkey_consumed_challenges.digest`: de dos inserciones del mismo
challenge, la base acepta una y la otra recibe `RecordNotUnique`. Las pruebas
reproducen el intercalado real (dos copias leídas antes de escribir), no dos
hilos: las pruebas transaccionales comparten conexión. No verifiqué la
carrera con dos conexiones reales en MySQL.

## Evidencia

SHA-256 de los archivos de prueba, idénticos en RED y GREEN:

| Archivo | SHA-256 |
|---|---|
| `test/lib/action_pack/passkey_test.rb` | `7bcb019332a0885a2ed6f1a2ab8b5fdcea7bdec73691571580e868b6c8938b45` |
| `test/controllers/sessions/passkeys_controller_test.rb` | `8561988a947d629913420063b198d1177f77e9f70d3593a759c3a9ad2a7bd32a` |
| `test/controllers/my/passkeys_controller_test.rb` | `0188818ad61edd02e6552ae25eb6c9150d41f3e1a60206a718eb8b850320adaf` |
| `test/lib/action_pack/web_authn/public_key_credential/request_options_test.rb` | `798178d1305a5fc4ab41942aedce1441beefc3732b4d83b76f3ffc6de645723e` |
| `test/lib/action_pack/web_authn/public_key_credential/creation_options_test.rb` | `fa01bdc16c76238a84974cf298df395089c4e7d984518034e279107f41dcc2b8` |

Comando, con Ruby 3.4.8 de mise y SQLite. RED corrió en una exportación
`git archive` de la base, con sólo esos cinco archivos copiados encima:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/lib/action_pack/passkey_test.rb \
    test/controllers/sessions/passkeys_controller_test.rb \
    test/controllers/my/passkeys_controller_test.rb \
    test/lib/action_pack/web_authn/public_key_credential/request_options_test.rb \
    test/lib/action_pack/web_authn/public_key_credential/creation_options_test.rb
```

RED, base: salida 1; 41 casos, 5 fallos, 3 errores.

- El replay HTTP redirige a `/landing` (segunda sesión) en lugar de
  `/session/new`.
- La segunda copia y el contador viejo autentican (`Expected #<ActionPack::Passkey …> to be nil`).
- `client_data_json` e `id` llegan sin filtrar a `filtered_parameters`.
- Errores esperados de API nueva: `ConsumedChallenge` no existe y el mensaje
  firmado no trae vencimiento (`can't convert nil into Integer`).

GREEN, con el arreglo:

| Comando | Resultado |
|---|---|
| El comando anterior más `test/lib/action_pack` y `my/passkey_challenges_controller_test.rb` | 210 casos, 397 aserciones, sin fallos |
| `bin/rails test` (SQLite, `SAAS=false`) | 1798 casos, 7043 aserciones, 0 fallos, 6 omitidos |
| `bin/rubocop` sobre los archivos tocados | sin ofensas |
| `bin/brakeman --exit-on-warn` | sin advertencias |

No verificado: la suite con MySQL y SaaS (`db/schema.rb` se editó a mano con
la misma forma que el dump de SQLite), y la carrera con dos conexiones reales.
