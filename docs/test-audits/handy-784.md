# Cancelación de cuentas y descargas de Active Storage

## Autoría antes de editar las pruebas

Base productiva: `5b201cf121ef92386655f15372603e351a68cb31` (incluye la
revisión auditada `25a93b13ec5a819fed72f956b64f7da424b5a852`).

- **Contrato:** una cuenta cancelada o un usuario desactivado no puede
  descargar adjuntos, variantes, representaciones ni exports por las rutas de
  Active Storage (redirect y proxy), con sesión o con token. Un adjunto de un
  tablero publicado deja de ser público cuando su cuenta se cancela. Un usuario
  sólo llega a adjuntos de su propia cuenta. Dueño:
  `lib/rails_ext/active_storage_authorization.rb`. Frontera: petición HTTP real
  a los controladores de Active Storage.
- **Regresión:** quitar `active_account_access?` de `ensure_accessible` permite
  descargar tras cancelar; quitar `account&.active?` de
  `Attachment#publicly_accessible?` deja público el adjunto de un tablero antes
  publicado; quitar la comparación de `account_id` deja que un acceso de otra
  cuenta autorice el adjunto.
- **Cobertura:** `active_storage_authorization_test.rb` ya cubría acceso por
  tablero, anónimo, tablero publicado, export y parser de representaciones,
  pero ningún caso cancelaba la cuenta ni desactivaba al usuario. Los controles
  de `Authorization` no se aplican a estos controladores, así que las pruebas
  de `account/cancellations_controller_test.rb` no los cubren. Se amplía el
  mismo archivo.
- **Seam:** ninguno nuevo. Se usan `Account#cancel`, `sign_in_as`, el token de
  API de los fixtures y las rutas de Active Storage. El caso de vínculo de
  cuenta inserta un `Access` cruzado con `insert_all`: el código productivo no
  lo crea; simula un dato inconsistente para probar la defensa adicional.

Casos nuevos: redirect y proxy tras cancelar; token tras cancelar; variante
(redirect y proxy, sin ejecutar el parser); usuario desactivado; tablero antes
publicado (blob, proxy y representación); export (redirect y proxy); vínculo
de cuenta.

## Evidencia

SHA-256 del archivo de prueba, idéntico en RED y GREEN:
`839fc34548d23f3baed877c622194a0d2961996f16f07b6c176cb42d9fc5ad08`.

Comando, desde `fizzy-custom/`, con Ruby 3.4.8 de mise y SQLite:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/integration/active_storage_authorization_test.rb
```

RED, con el código productivo de la base y la prueba nueva: salida 1; 34
casos, 125 aserciones, 7 fallos, cero errores. Seis casos reciben `302` hacia
`rails/active_storage/disk/…` (archivo servido) donde se espera `403` o el
login; el de variantes ejecuta `Blob#representation` tras cancelar.

GREEN, con el arreglo: el mismo archivo más `pagination_blob_html_xss_test.rb`,
`blob_key_traversal_test.rb`, `users/avatars_controller_test.rb` y
`accounts/exports_controller_test.rb`: 66 casos, 313 aserciones, sin fallos.

| Comando | Resultado |
|---|---|
| `PARALLEL_WORKERS=4 mise exec -- bin/rails test` | Salida 0; 1.789 casos, 7.014 aserciones, 6 omisiones, sin fallos ni errores |
| `mise exec -- bin/rubocop -f simple` sobre los dos archivos Ruby del diff | Sin infracciones |

## Límites

Una URL de servicio ya emitida (`rails/active_storage/disk/…` o una URL
firmada de S3) sigue válida hasta que expira (5 minutos por defecto). El
arreglo impide emitir nuevas URLs después de cancelar; no revoca las ya
entregadas. Las pruebas de sistema no se ejecutaron: el cambio no toca vistas.
