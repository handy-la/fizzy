# Almacenamiento SaaS: TLS y separación de entornos

`saas/config/environments/production.rb` selecciona `purestorage`. Beta y
staging heredan esa selección. `saas/config/storage.yml` exige verificar
la cadena y el nombre del certificado de `storage.basecamp.com`.
No desactives esa verificación para recuperar el servicio.

La instancia OSS de Handy usa Disk por defecto. Este procedimiento aplica al
operador del almacenamiento SaaS. No cambia el almacenamiento de Handy.

## Preparación antes del despliegue

1. Emite e instala un certificado de servidor válido para
   `storage.basecamp.com`, con su cadena intermedia completa. Usa una CA del
   sistema o la CA interna de la organización. La clave privada queda en el
   servidor de almacenamiento, nunca en el repositorio ni en la imagen de Fizzy.
2. Para una CA interna, monta su bundle PEM de certificados públicos, de sólo
   lectura, en cada proceso web y worker. Define
   `ACTIVE_STORAGE_SSL_CA_BUNDLE` con la ruta absoluta dentro del contenedor,
   por ejemplo `/etc/fizzy/storage-ca.pem`. Si no defines esa variable, el SDK
   usa las CA predeterminadas. El bundle debe proceder del administrador de la
   CA, no del servidor que estás verificando.
3. Crea los buckets y las políticas por entorno:

   | Entorno | Bucket autorizado |
   |---|---|
   | production | `fizzy-production-activestorage` |
   | beta | `fizzy-beta-activestorage` |
   | staging | `fizzy-staging-activestorage` |

   Configura una identidad distinta por entorno mediante
   `ACTIVE_STORAGE_ACCESS_KEY_ID` y `ACTIVE_STORAGE_SECRET_ACCESS_KEY`.
   Limita las operaciones de bucket y objeto al bucket de esa identidad.
   Un nombre diferente de bucket no sustituye una política de permisos.
4. Beta antes compartía el bucket de producción. Detén sus escrituras y jobs
   durante el corte. Identifica sus blobs en la base beta y copia sólo sus
   objetos al bucket beta, conservando sus claves y metadatos. Verifica cantidad,
   tamaño y contenido. No vacíes el bucket de producción: otros entornos
   podían usar esos mismos objetos. Prepara un respaldo y un plan de corte
   antes de cambiar las credenciales de beta.

## Comprobación del certificado

Antes de dar credenciales a un proceso, comprueba el certificado con el mismo
bundle que verá ese proceso:

```sh
openssl s_client -connect storage.basecamp.com:443 \
  -servername storage.basecamp.com -verify_hostname storage.basecamp.com \
  -verify_return_error -CAfile /etc/fizzy/storage-ca.pem </dev/null
```

La verificación debe terminar con código 0. Sin CA interna, omite `-CAfile`.
En un entorno de prueba, presenta un certificado de una CA no confiable y
repite el comando: debe terminar con error. No sustituyas certificados del
servicio de producción para hacer una prueba negativa.

La regresión automatizada usa el adaptador S3 real de Active Storage. Un
servidor TLS local con CA desconocida o nombre incorrecto no debe recibir
ninguna petición HTTP. Con la CA configurada debe recibir una carga firmada y
una descarga del mismo contenido:

```sh
env -u GEM_HOME -u GEM_PATH -u RUBYOPT -u BUNDLE_PATH -u BUNDLE_GEMFILE \
  SAAS=false BUNDLE_GEMFILE=Gemfile CI_PROGRESS_BAR=false PARALLEL_WORKERS=2 \
  mise exec -- bundle exec bin/rails test test/lib/saas_storage_tls_test.rb
```

## Corte, rotación y comprobación operativa

1. Con el certificado y los buckets preparados, despliega la configuración
   y reinicia web y workers. Comprueba una carga y descarga con una clave de
   prueba aleatoria en **cada** entorno. Compara los bytes y borra el objeto de
   prueba. Comprueba también la descarga de un adjunto antiguo de beta.
2. Después de validar TLS, rota las credenciales de los tres entornos con
   identidades limitadas a sus buckets. Actualiza el gestor de secretos y todos
   los procesos que usan S3. Revoca las credenciales anteriores. No publiques
   valores de claves ni cabeceras firmadas en la tarjeta o los logs.
3. Con cada identidad nueva, verifica que puede listar y cargar, descargar y
   borrar en su bucket. Comprueba que recibe `AccessDenied` (403) al listar los
   otros dos buckets y leer un objeto de prueba conocido de esos buckets.
   Revisa además las políticas de escritura y borrado: no deben autorizar
   recursos de otros entornos. Un 404 no demuestra aislamiento.
4. Registra sólo el entorno, el bucket, el resultado TLS, el resultado de
   carga/descarga, la revocación y las denegaciones entre entornos. No cierres
   la tarea operativa si falta alguna comprobación.

El SDK verifica TLS por defecto y admite `ssl_ca_bundle` como ruta PEM:
[documentación de AWS S3 para Ruby](https://docs.aws.amazon.com/sdk-for-ruby/v3/api/Aws/S3/Client.html).

## Recuperación

Si el certificado o la CA no pasan la comprobación, detén el corte y corrige
la cadena, el nombre o el montaje. Mantén la verificación activa. Si falla la
migración beta, conserva el respaldo y detén sus escrituras hasta corregirla.
Volver al bucket compartido o a credenciales sin límites requiere una decisión
operativa explícita; no es una recuperación automática.
