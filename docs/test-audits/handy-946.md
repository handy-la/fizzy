# Límite de claves RSA en passkeys: Handy 946

## Autoría antes de editar las pruebas

- **Contrato:** el registro de una passkey RS256 acepta un módulo de 2048 a
  4096 bits y sólo el exponente público 65537. Rechaza los otros valores
  antes de crear `OpenSSL::BN` o enteros ASN.1, y no persiste la credencial.
  Dueño: `ActionPack::WebAuthn::CoseKey#build_rsa_rs256_key`. Fronteras: la
  conversión de la clave COSE y la petición HTTP real a `My::PasskeysController#create`.
- **Regresión:** quitar el límite superior del módulo o la lista del
  exponente permite guardar una clave que cuesta CPU en cada verificación de
  `AssertionResponse`. Mover la comprobación después de `OpenSSL::BN.new`
  convierte primero un número de varios MB. Las pruebas observan la fila no
  creada, la respuesta HTTP y la ausencia de llamadas a `OpenSSL::BN.new` y
  `OpenSSL::ASN1.Integer`.
- **Cobertura:** `CoseKeyTest` probaba sólo el mínimo de 2048 bits y `e=1`.
  `My::PasskeysControllerTest` registraba sólo una clave EC2. Ninguna prueba
  registraba RS256 por HTTP ni comprobaba un máximo. Se agregan casos a esas
  dos clases; el caso de controlador protege la persistencia, el de
  `CoseKey` el orden de las comprobaciones.
- **Seam:** `WebauthnTestHelper#build_attestation_params` recibe ahora
  `cose_public_key:` (EC2 por defecto) y calcula la cabecera CBOR de
  `authData`. Sólo lo usan pruebas. No se agrega una API productiva.

Una petición de challenge sin tenant redirige después de usar un helper de
ruta en una aserción (`assert_redirected_to edit_my_passkey_path(...)`): el
challenge sale `nil` y el registro falla por «Challenge missing». Por eso cada
prueba hace un solo registro y comprueba que recibió un challenge.

## Evidencia

Base del repo, sin el arreglo: `1cde149e8e7b1f71fdcd25479ccb7ac3f5578f00`.
Ruby 3.4.8 de mise, OpenSSL 3.5.5, SQLite OSS. Comando desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/lib/action_pack/web_authn/cose_key_test.rb \
  test/controllers/my/passkeys_controller_test.rb
```

SHA-256 de los archivos de prueba, iguales en RED y GREEN:

- `test/lib/action_pack/web_authn/cose_key_test.rb`:
  `0cec0978e43fcfa15189f6a6f00e00d9bca904687d6eedef58bc7aca627ca8e4`.
- `test/controllers/my/passkeys_controller_test.rb`:
  `cd884199cc0b010ea43435dd23a37a41e13deba554738920e05e49c4e79bebcd`.
- `test/test_helpers/webauthn_test_helper.rb`:
  `06e6855090f802e3a8dbc4c38ba04b15fd8b192cfaab60f4899155fc81b33a34`.

RED, con las pruebas aplicadas sobre la base: salida 1, `36 runs, 133
assertions, 7 failures, 0 errors`. Fallan por la causa esperada:

- se registran las claves con módulo de 4097 bits y de 64 KiB, y las de
  exponente 3, 2^32 + 1 y uno impar de 8 KiB;
- `CoseKey` llama a `OpenSSL::BN.new` con el módulo de 4097 bits y con un
  exponente no permitido.

Los casos de 2048 y 4096 bits, el exponente par y el módulo con un cero
inicial pasan en la base: protegen que el arreglo no rechace claves válidas.

GREEN, con el arreglo: salida 0, `36 runs, 176 assertions, 0 failures`.
Suite `bin/rails test` completa: `1935 runs, 0 failures, 0 errors, 6 skips`.

### RED repetido sobre la base rebasada

Después del rebase sobre `c4f525ef777dbf57572aa1157406cdc5e11b8e2e` (handy-945), `PasskeyTest` usa
`ATTESTATION_OBJECT_CBOR_PREFIX` con auth data EC2 de 164 bytes. El helper
conserva esa constante y agrega `ATTESTATION_OBJECT_MAP_PREFIX` para
`build_attestation_params`. Por ese cambio se repitió el RED con los archivos
finales. SHA-256:

- `test/lib/action_pack/web_authn/cose_key_test.rb`: sin cambio (`0cec0978…`).
- `test/controllers/my/passkeys_controller_test.rb`: sin cambio (`cd884199…`).
- `test/test_helpers/webauthn_test_helper.rb`:
  `b2e1390e7604e5aa01583ed6f208c63a0e1baa0a7def307c52257fea4f17b403`.
- `test/lib/action_pack/passkey_test.rb` (de la base):
  `e51817dc2856eff795aa1fcb421edc3b563c53d7968f7489bc1d20ea31e75cf0`.

Método: en este checkout, `lib/action_pack/web_authn/cose_key.rb` se
reemplazó por `git show c4f525ef777dbf57572aa1157406cdc5e11b8e2e:lib/action_pack/web_authn/cose_key.rb`;
`git diff --quiet c4f525ef777dbf57572aa1157406cdc5e11b8e2e -- lib app config` confirmó que el código
productivo era el de la base. Después se restauró con `git checkout HEAD --`.
Mismo comando de arriba, con `test/lib/action_pack/passkey_test.rb` agregado.

- RED: salida 1, `55 runs, 166 assertions, 7 failures, 0 errors`. Fallan
  los mismos siete casos que en el primer RED; `PasskeyTest` pasa.
- GREEN: salida 0, `55 runs, 209 assertions, 0 failures, 0 errors`.
- Suite `bin/rails test` completa: `1944 runs, 0 failures, 0 errors, 6 skips`.

No se verificó: claves RSA ya guardadas antes de este cambio. El límite
actúa en el registro; una credencial existente no se vuelve a validar.

## Excepción de rondas de revisión

`main` avanzó tres veces durante el aterrizaje, y dos de esos commits
editaron `CLAUDE.md`. La huella de `bin/signoff` incluye la versión base de
cada archivo del diff, así que cada uno venció un PASS con el patch idéntico.
La persona autorizó en la tarjeta la ronda 4 (`CHANGE_REVIEW_MAX_ROUNDS=4`) y
después la ronda 5 (`CHANGE_REVIEW_MAX_ROUNDS=5`), con la misma serie y el
mismo `CHANGE_REVIEW_CONTEXT`. Para la ronda 5, la nota de `CLAUDE.md` salió de
este cambio y se sube después en un commit sólo de documentación. Su regla:
una clave RS256 se acepta con módulo de 2048 a 4096 bits y exponente 65537,
comprobados sobre los bytes antes de `OpenSSL::BN`; en una prueba de
integración, haz un registro de passkey por prueba (ver arriba).
