# Handy 1203: el QR no lleva su capacidad en una URL

Hallazgo `csf_b848ad2d36b74753d541a6a6`, revisión auditada `b9e10f1f8b0c`.

## Problema

`qr_code_image(url)` firmaba la URL con `QrCodeLink` (firma, sin cifrado) y
la ponía en `/qr_codes/:id`. `QrCodesController` usaba
`allow_unauthenticated_access` y `Cache-Control: public, max-age=1 año`. El
navegador pedía esa ruta para mostrar el QR, y el registro de Rails guarda la
ruta completa. El valor es Base64 de la URL: un lector del registro (o de un
proxy o caché intermedio) recuperaba el enlace de auto-login de
`users/_transfer` (vigente 4 horas) o el enlace de invitación de
`account/join_codes/show`.

## Corrección

`QrCodesHelper#qr_code_image` genera el SVG en el servidor y lo inserta en la
página como `data:image/svg+xml;base64,…` dentro de un `img`. La página que lo
muestra ya exige sesión y responde `no-store`. El `img` conserva clase y `alt`,
así que no hay cambio visual. `img-src` ya admite `data:`.

Se retiran `QrCodesController`, `QrCodeLink` y la ruta `resources :qr_codes`.
Una URL `/qr_codes/…` capturada antes responde 404, con o sin sesión. No queda
identificador de QR: no hace falta expiración propia ni filtrar la ruta en los
registros, porque no existe ninguna petición del QR.

`Identity::Transfer.consume` no cambia: el canje sigue siendo un `DELETE` por
id y vigencia que debe borrar una fila (`sessions/transfers_controller_test.rb`
y `transfer_tokens_controller_test.rb` siguen verdes).

Límite conocido: la URL de canje `/session/transfers/:token` aparece en el
registro cuando el otro dispositivo la abre. La página envía el `PUT` al
cargar y el canje borra el token; esta tarjeta no cambia esa ruta.

## Pruebas (cuatro respuestas)

`test/integration/qr_code_capability_test.rb`, tres casos.

- **Contrato:** el QR de auto-login (`GET /users/:id` propio) y el de
  invitación (`GET /account/join_code`) están dentro del HTML como data URI
  con un SVG, y el cuerpo no contiene `/qr_codes/`. Una URL del formato
  anterior (firmada con la clave `qr_codes`, propósito `:qr_code`) responde
  404 sin sesión y sin SVG. Dueño: `QrCodesHelper` y `config/routes.rb`.
  Frontera: petición HTTP completa.
- **Regresión:** volver a un `img` con URL propia, o volver a montar un
  endpoint que acepte el formato firmado, hace fallar el caso correspondiente.
- **Cobertura:** `qr_codes_controller_test.rb` afirmaba lo contrario (200 sin
  sesión) y `qr_code_link_test.rb` sólo probaba la firma; ninguna prueba
  revisaba el HTML de las dos pantallas.
- **Seam:** ninguno nuevo.

## Retirada

| Campo | Evidencia |
|---|---|
| Identidad | `test/controllers/qr_codes_controller_test.rb` (`show`) y `test/models/qr_code_link_test.rb`; símbolos `QrCodesController#show` y `QrCodeLink` |
| Fallo detectable | Que el endpoint público sirviera un SVG y que la firma fuera verificable |
| Consumidores | `rg` en todo el repo (app, config, test, saas, docs): sólo el helper |
| Cobertura restante | El contrato se invierte; el caso 3 de la prueba nueva exige 404 |
| Historia | Creado en `592c88e6` (Add session transfer feature, 2024-12-18) |
| Riesgo | Ninguno: el código retirado era el vector |
| Decisión | Retirar con su código |

## RED y GREEN

Repo `fizzy-custom`, base `eddc916fcacdfa28f0ab478af217460d7cd8c5c4`, Ruby
3.4.8 (mise), sin variables de RVM/Bundler heredadas:

```bash
SAAS=false BUNDLE_GEMFILE=Gemfile mise exec -- bin/rails test test/integration/qr_code_capability_test.rb
```

- Base (prueba nueva, código sin cambio): 3 fallos. Los dos de pantalla:
  `QR code src should be a data URI, was /897362094/qr_codes/eyJfcmFpbHMi…`.
  El de URL capturada: `Expected response to be a <404: missing>, but was a <200: OK>`.
- Con el arreglo, junto con `users_controller_test.rb`,
  `accounts/join_codes_controller_test.rb`,
  `sessions/transfers_controller_test.rb` y
  `transfer_tokens_controller_test.rb`: 40 pruebas, 0 fallos.
