# Handy 964: certificado del almacenamiento SaaS

## Autoría antes de editar las pruebas

- **Contrato:** `saas/config/storage.yml`, consumido por Active Storage en
  producción, beta y staging, debe verificar la cadena y el nombre del
  certificado antes de enviar HTTP firmado. Una CA interna explícita permite
  cargar y descargar. Cada entorno usa su propio bucket.
- **Regresión:** desactivar `ssl_verify_peer` permite enviar HTTP al servidor
  no confiable o con otro nombre. Omitir el bundle impide la carga con la CA
  interna. Volver a mapear beta a producción rompe la separación de buckets.
- **Cobertura:** `test/models/webhook/tls_test.rb` prueba otro cliente, Net::HTTP
  de webhooks. Las pruebas de cuotas y transferencia de Active Storage usan
  Disk y no comprueban el transporte S3 ni la configuración SaaS. Los nuevos
  casos estarán en `test/lib/saas_storage_tls_test.rb` y ejecutarán el adaptador
  S3 real con la configuración YAML/ERB productiva.
- **Seam:** ninguno nuevo en producción. El test carga el YAML SaaS aunque
  arranque el runner OSS, cambia temporalmente `Rails.env` y variables de
  entorno, y sustituye sólo el destino por un servidor TLS local. Usa
  credenciales ficticias. Desactiva WebMock durante el transporte y lo restaura.

## Evidencia RED y GREEN

Base de `fizzy-custom`: `fb2af95ebcd8317391d7b3c7f715d22f97e81ffb`.
Se exportó ese commit con `git archive` a una carpeta temporal aislada dentro
de `.context/handy-964/` del workspace y se copió sólo la prueba candidata.
La configuración productiva de la exportación se dejó sin cambios.

Versión de la prueba: SHA-256
`d961a770a24be44f4b693caab3a807cd9238ca9c6987b6f05e2d4fd230183e8e`.
Ruby 3.4.8, SDK S3 1.231.0, SDK core 3.257.0; sin SaaS activo ni red externa.
`mise` seleccionó Ruby desde el checkout original antes de entrar a la
exportación. `BASE_EXPORT` es la ruta absoluta de esa exportación:

```sh
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u BUNDLE_PATH -u BUNDLE_GEMFILE \
  SAAS=false BUNDLE_GEMFILE=Gemfile CI_PROGRESS_BAR=false PARALLEL_WORKERS=2 \
  mise exec -- ruby -C "$BASE_EXPORT" -S bundle exec ruby bin/rails test \
  test/lib/saas_storage_tls_test.rb
```

RED: salida 1; `4 runs, 14 assertions, 3 failures, 0 errors, 0 skips`.
Los dos casos negativos esperaban `Seahorse::Client::NetworkingError`, pero
la carga terminó sin excepción con certificados no confiables o con otro
nombre. El aislamiento esperaba `fizzy-beta-activestorage` y recibió
`fizzy-production-activestorage`. El caso de carga/descarga pasó en la base
porque ésta no verificaba ningún certificado.

GREEN: mismo runner, entorno y prueba, contra la configuración corregida en
el checkout de esta tarjeta, sin `ruby -C "$BASE_EXPORT"`:

```sh
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u BUNDLE_PATH -u BUNDLE_GEMFILE \
  SAAS=false BUNDLE_GEMFILE=Gemfile CI_PROGRESS_BAR=false PARALLEL_WORKERS=2 \
  mise exec -- bundle exec bin/rails test test/lib/saas_storage_tls_test.rb
```

Salida 0; `4 runs, 29 assertions, 0 failures, 0 errors, 0 skips`.
La CA desconocida y el nombre incorrecto se rechazan antes de HTTP. El caso
positivo usa una hoja firmada por una CA de prueba que sólo está en el bundle
configurado; no se inyecta un almacén de confianza en el cliente desde el test.
Carga y descarga pasan con el mismo contenido y una petición firmada.

## Validación del lote

Desde `fizzy-custom/`, con el mismo entorno anterior:

- `mise exec -- bundle exec bin/rails test`: salida 0;
  `2050 runs, 8645 assertions, 0 failures, 0 errors, 6 skips`.
- `mise exec -- bundle exec bin/rubocop test/lib/saas_storage_tls_test.rb -f simple`:
  salida 0; un archivo, sin infracciones.
- `script/check_agents_docs`: salida 0; cuatro archivos comprobados.
- `git diff --check`: salida 0.

No se retiraron pruebas ni se agregaron seams productivos.

## Qué no se pudo verificar

La instancia de Handy es OSS y usa Disk. Este worktree no administra
`storage.basecamp.com`, su CA ni sus permisos S3. La emisión de certificado,
creación y migración del bucket beta, políticas de acceso y rotación requieren
al operador de ese servicio. Las pruebas locales no certifican esos cambios.
No se ejecutó la suite SaaS con MySQL ni las pruebas de navegador: el cambio
no afecta las pantallas, y el transporte SaaS se comprueba desde el runner OSS
contra su YAML real. Las seis omisiones de la suite OSS quedan declaradas;
la prueba TLS nueva no tiene omisiones.

## Extensión tras la primera revisión de signoff

Signoff encontró un bloqueante: `ZipFile.read_from_s3` sólo transmitía
`ssl_verify_peer` a `ZipFile::RemoteIO`; el lector abría otro `Net::HTTP` sin
la CA configurada. La secuencia inicial de bloqueantes es `1`.

Autoría antes de agregar los casos del lector remoto:

- **Contrato:** una lectura de importación S3 mediante `ZipFile.read_from`
  conserva la confianza TLS del servicio de Active Storage, tanto para el
  tamaño como para los rangos del archivo. Rechaza servidores no confiables.
- **Regresión:** omitir `ssl_ca_bundle` en el traspaso o en `http.ca_file`
  impide leer el ZIP firmado por la CA interna.
- **Cobertura:** los cuatro casos previos sólo ejercen el SDK S3. Los casos
  de rangos en `test/models/zip_file/structure_test.rb` simulan HTTP con
  WebMock, por lo que no prueban la cadena del certificado.
- **Seam:** ninguna API sólo para tests. `ZipFile.read_from` es la entrada
  productiva de importaciones. La prueba construye un blob sin guardar,
  asigna su servicio S3 real y obtiene su URL firmada real. El servidor TLS
  local sirve el ZIP por rangos y registra las peticiones.

Base del RED adicional:
`9639dfd0a9b8cdaa3b37af187d84ca298f4ea7b6`, el primer arreglo sin el
traspaso de CA. Se exportó con `git archive` a otra carpeta temporal aislada
de `.context/handy-964/`, y se copió la prueba extendida. Misma selección de
Ruby, entorno y comando RED anteriores, con `BASE_EXPORT` apuntando a esa
exportación. Versión extendida: SHA-256
`32aec67dee19b8b008c34266633fa73694b55bb2fdbe14a61420e4623d35fbf5`.

RED adicional: salida 1;
`7 runs, 35 assertions, 0 failures, 1 errors, 0 skips`.
El caso positivo de importación falló en `ZipFile::RemoteIO#with_http` con
`OpenSSL::SSL::SSLError: certificate verify failed (unable to get local issuer certificate)`.
Es un fallo del contrato TLS, no un error de carga o de infraestructura.

Delta del único bloqueante: `ZipFile.read_from_s3` transmite el bundle
del cliente S3 a `RemoteIO`; éste lo aplica en `Net::HTTP#ca_file` antes de
abrir la conexión. Los casos nuevos usan una URL firmada real y un ZIP
servido por rangos. Los rechazos no reciben ninguna petición HTTP.

GREEN adicional, mismo comando de prueba enfocada en el checkout corregido:
salida 0; `7 runs, 41 assertions, 0 failures, 0 errors, 0 skips`.
Suite final con el comando completo anterior: salida 0;
`2053 runs, 8657 assertions, 0 failures, 0 errors, 6 skips`.
RuboCop del test y de los dos archivos productivos modificados: salida 0,
tres archivos sin infracciones. `git diff --check`: salida 0.

Las observaciones no bloqueantes de los gates no originaron cambios.
