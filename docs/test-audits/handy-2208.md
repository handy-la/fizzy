# Handy 2208: destino de regreso sólo para GET de HTML

## Autoría antes de editar las pruebas

- **Contrato:** sin sesión, `Authentication#request_authentication` guarda
  `request.url` como destino de regreso sólo si la petición es GET y HTML.
  Después del login, `after_authentication_url` redirige con GET a ese
  destino o, si no hay destino, a `landing_url`. Dueño: el concern
  `Authentication`. Frontera: petición de integración real, sesión de Rails y
  el login por magic link (`sign_in_as`).
- **Regresión:** guardar `request.url` para todo método o formato. Un PUT
  `/my/timezone` (el formulario automático de zona horaria de una página con
  la sesión revocada) vuelve después del login como GET a una acción que no
  existe: «Unknown action … My::TimezonesController».
- **Cobertura:** `controller_authentication_test.rb` sólo comprobaba la
  redirección al login. `join_codes_controller_test.rb` comprueba un destino
  guardado por un GET; `shipped_client_authentication_test.rb` comprueba que
  un JSON sin credenciales redirige al login, sin mirar el destino. Ninguna
  cubre un método distinto de GET ni un formato distinto de HTML. Se agregan
  tres casos en `controller_authentication_test.rb`: PUT y luego login, GET
  JSON, y GET HTML que vuelve a su URL después del login.
- **Seam:** no se agrega ninguno.

Trampa: en el caso del PUT no se llama un helper de ruta con
`script_name: nil` antes de `sign_in_as`. Hacerlo cambia las opciones de URL
de la sesión de integración y el login de prueba falla (sin cookie
`session_token`), sin relación con el arreglo.

## RED y GREEN

Base de `fizzy-custom`: `9823854be374e2316977457c0c0ef222eb0b74d0`, sin el
arreglo en `app/controllers/concerns/authentication.rb`. Ruby 4.0.9 por mise,
SQLite, sin variables Ruby/Bundler heredadas:

```bash
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u BUNDLE_GEMFILE -u BUNDLE_PATH \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 \
  mise exec -- ruby bin/rails test test/controllers/controller_authentication_test.rb
```

- **RED (base):** exit 1, `6 tests, 20 assertions, 2 failures`.
  `Expected "http://www.example.com/897362094/my/timezone" to be nil.` y
  `Expected "http://www.example.com/897362094/boards.json" to be nil.`
- **GREEN (arreglo):** `6 tests, 23 assertions, 0 failures`.

La prueba de sistema de la tarjeta,
`test/system/private_offline_cache_test.rb`, con el mismo entorno, pasó en
3 corridas aisladas seguidas: `7 tests, 40 assertions, 0 failures` cada una.
Antes fallaba en 1 de cada 3 corridas (Handy 2119, en la misma base).
