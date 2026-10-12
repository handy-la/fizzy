# Política `user_verification` de passkeys: Handy 945

## Hallazgo

La API envía `userVerification: required` al navegador, pero el servidor
valida la respuesta con `preferred`. Un cliente modificado puede omitir el PIN
o la biometría (flag UV). Auditoría `csf_17671c120bfc857e74d57fba`.

## Corrección

- `ActionPack::Passkey.register` y `#authenticate` calculan la política efectiva
  en el servidor: `default_creation_options` / `default_request_options` más
  las opciones del holder, con el mismo orden de mezcla que las opciones
  enviadas al navegador. En autenticación, la política del holder se lee
  después de localizar la credencial.
- `PublicKeyCredential.register` y `#authenticate` pasan esa política a
  `AttestationResponse` y `AssertionResponse`.
- El challenge firmado lleva la política: `<nonce>:<user verification>:<expiry>`.
  El endpoint de challenges firma el valor configurado para la ceremonia.
- `Response` exige UV cuando la política del servidor **o** la firmada es
  `required`. Un cambio de política entre emisión y validación sólo puede
  endurecer la ceremonia. Un challenge del formato anterior no tiene política
  firmada; la política del servidor sigue aplicando.
- Una política desconocida (`"require"`) produce `InvalidOptionsError`; antes
  no verificaba nada.

Límite conocido: una opción pasada sólo en la llamada
(`authentication_options(user_verification: :required)`) no se puede
recalcular. Sólo la protege el challenge firmado cuando el navegador usa ese
challenge. El JavaScript de Fizzy pide un challenge nuevo al endpoint, que
firma la política configurada. Fizzy no usa opciones de llamada.

## Autoría antes de editar las pruebas

- **Contrato:** con política `required` (configuración global o holder), el
  servidor rechaza una aserción o un registro firmado con UP sin UV, y acepta
  la misma credencial con UP y UV. Dueños: `ActionPack::Passkey`,
  `ActionPack::WebAuthn::Authenticator::Response` y
  `ActionPack::Passkey::ChallengesController`. Frontera: las entradas públicas
  `ActionPack::Passkey.authenticate` y `holder.passkeys.register`, que usan
  `Sessions::PasskeysController` y `My::PasskeysController`.
- **Regresión:** no pasar la política a la respuesta, leerla antes de conocer
  el holder, o validar con `preferred` deja pasar la respuesta sin UV. Quitar
  la política del challenge permite relajarla entre emisión y validación.
- **Cobertura:** `AssertionResponseTest` prueba `required` sólo cuando el
  llamador pasa la política a mano; ninguna prueba cubría el camino productivo
  de `ActionPack::Passkey`. Las pruebas de `CreationOptions`/`RequestOptions`
  fijaban el formato anterior del challenge; se amplían para fijar el nuevo.
- **Seam:** ninguno nuevo. `registration_user_verification` y
  `authentication_user_verification` son públicos porque `register` (clase)
  los llama sobre una instancia. Las pruebas cambian la configuración real y
  usan `Identity.any_instance.stubs` para la política del holder, porque
  `Identity` no declara una.

Casos nuevos en `test/lib/action_pack/passkey_test.rb` (siete), en
`assertion_response_test.rb` (política desconocida) y en
`passkey_challenges_controller_test.rb` (política firmada por el endpoint).
Casos modificados: el challenge firmado de `creation_options_test.rb` y
`request_options_test.rb`.

## Evidencia

Base del repo: `1cde149e8e7b1f71fdcd25479ccb7ac3f5578f00` (`origin/main`).
Desde `fizzy-custom/`, Ruby de mise, SQLite OSS:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u BUNDLE_GEMFILE \
  -u BUNDLE_PATH SAAS=false CI_PROGRESS_BAR=false PARALLEL_WORKERS=1 \
  mise exec -- bin/rails test test/lib/action_pack/passkey_test.rb \
  test/lib/action_pack/web_authn/authenticator/assertion_response_test.rb \
  test/controllers/my/passkey_challenges_controller_test.rb \
  test/lib/action_pack/web_authn/public_key_credential/creation_options_test.rb \
  test/lib/action_pack/web_authn/public_key_credential/request_options_test.rb
```

- **RED:** las pruebas nuevas, copiadas sobre una exportación `git archive`
  de la base: salida 1; 54 casos, 10 fallos de aserción, 0 errores. Las
  aserciones fallidas: aserción sin UV aceptada (cuatro de `PasskeyTest`),
  registro sin UV aceptado (dos), política desconocida sin error, y política
  ausente del challenge (tres).
- **GREEN:** el mismo conjunto con el arreglo, más `test/controllers/my` y
  `test/controllers/sessions`: 265 casos, 0 fallos.
