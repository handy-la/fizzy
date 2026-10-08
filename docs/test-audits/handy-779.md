# Cuota de cargas directas

## Autoría antes de editar pruebas

Base: `f25c72da9ba17a7f184fa2c29673ad3670ff0546`.

- **Contrato:** antes de emitir una URL, una carga debe reservar su tamaño en
  la cuenta. El máximo por objeto es 100 MiB; la cuota predeterminada del
  servidor propio es 10 GiB. SaaS conserva su cuota y sus excepciones.
  Se permiten 20 cargas pendientes por identidad y 100 por cuenta. El consumo
  incluye reservas. Al adjuntar, el cargo pasa al registro de adjuntos en la
  misma transacción. La limpieza borra objetos vencidos antes de liberar el
  cargo. Tras quitar el último adjunto, el cargo vuelve a una reserva hasta
  que la URL ya no pueda recrear el objeto. Dueños: controlador de cargas, `Storage::UploadReservation` y
  `Storage::AttachmentTracking`. Fronteras: HTTP, transacción y almacenamiento.
- **Regresión:** autorizar antes de reservar acepta objetos excesivos; leer la
  cuota sin serializar acepta dos reservas que juntas exceden el saldo;
  liberar antes de borrar permite consumo sin cargo si falla el almacenamiento;
  mover el cargo después del commit abre una ventana sin cuota.
- **Cobertura:** `active_storage/direct_uploads_controller_test.rb` sólo prueba
  autenticación y respuesta. `storage/totaled_test.rb` cubre registros y
  snapshots, sin cargas pendientes. `storage/tracked_test.rb` cubre adjuntos,
  sin reservas ni limpieza. Se amplía el primero y se agrega la prueba del
  ciclo de vida y concurrencia, que tiene una frontera distinta.
- **Seam:** no se agrega una API para pruebas. El controlador usa el modelo de
  reservas; los callbacks consumen reservas y el trabajo periódico las purga.
  La concurrencia usa conexiones reales y datos confirmados, sin mock de locks.

## Evidencia

Ruby 3.4.8 de mise, `SAAS=false`, Gemfile OSS y SQLite. SHA-256 del archivo
HTTP, idéntico en RED y GREEN:
`fdcfed6385806a89acdef9d79dfe82d71902e987b31c3edc382c490e2ec70c0a`.

Se exportó la base con `git archive` a `.context/fizzy-779-red`, sin tocar otro
checkout. Se copió sólo la prueba HTTP candidata a la exportación. Desde
`fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bash -c 'cd ../.context/fizzy-779-red && bin/rails test test/controllers/active_storage/direct_uploads_controller_test.rb'
```

RED: salida 1; 16 casos, 70 aserciones, seis fallos, cero errores. La base
responde 200 al objeto excesivo, al saldo insuficiente, a la reserva número
21 y al tamaño cero; deja el consumo en cero tras reservar; la URL de carga
sigue aceptando PUT a las dos horas. El tamaño real mayor al declarado ya
recibía 422 de Disk; ese control se conserva.

GREEN usa el mismo entorno desde el checkout de la tarjeta, sin cambiar de
directorio, con `mise exec -- bin/rails test`. Salida 0: **1.818 casos, 7.160
aserciones, cero fallos, cero errores y seis omisiones**. Incluye la prueba
HTTP idéntica, las pruebas nuevas del ciclo de vida y los casos existentes de
ledger, borrado, exportación e importación. El lote enfocado antes de agregar
los dos últimos casos HTTP: 121 casos, 389 aserciones, salida 0.

`mise exec -- bin/rubocop -f simple` sobre los diez archivos Ruby modificados
(no migración ni schemas): salida 0, sin infracciones. `git diff --check`:
salida 0.

### Excepción RED limitada al nuevo modelo y su tabla

Los casos de limpieza, transferencia de reserva, avatar, rollback, fallo de
borrado, saldo personalizado, limpieza histórica y concurrencia usan una tabla
y una entrada productiva nuevas. No se puede aplicar ese archivo sin la tabla
a la base y obtener un fallo por el contrato: se obtendría una clase o tabla
ausente, que no se registra como RED. La evidencia histórica del defecto es
el RED HTTP anterior, con el código base íntegro. El riesgo de ciclo de vida
se comprueba en GREEN con archivos reales, rollback y una excepción de servicio
que conserva la clave y la reserva y luego se reintenta con éxito. La prueba
de cuota concurrente desactiva las transacciones de fixtures, confirma sus
propios datos y usa dos conexiones y dos identidades reales. Una reserva se
acepta y la otra se rechaza; su suma coincide con el saldo disponible.

El caso de cuota personalizada sustituye el lector productivo `storage_limit`
de SaaS en una cuenta del entorno OSS; no agrega una API para pruebas.

## Decisiones de seguridad y operación

- `bytes_used` suma reservas al snapshot; `bytes_used_exact` suma reservas al
  ledger exacto. La autorización usa el segundo bajo el lock de cuenta.
- Los límites de pendientes también incluyen objetos en espera de borrado.
  Los metadatos de identidad y vencimiento se fijan en el servidor.
- Un fallo al emitir la URL revierte blob y reserva. S3 no notifica a Rails
  cada PUT fallido; una URL ya emitida permanece reservada hasta vencer y
  completar el borrado. Liberarla antes permitiría reutilizarla sin cargo.
- La URL nueva vence en una hora, separada de la reserva del borrador. Cada
  15 minutos la limpieza elimina cargas sin objeto después de la URL y una
  hora de margen. Un archivo subido conserva su reserva 30 días, para que una
  pausa del editor no borre su imagen. Puede adjuntarse mientras el blob exista.
  Después de esos 30 días y el margen, se purga como borrador abandonado. Esta
  conservación finita cumple la limpieza solicitada y limita el consumo con
  la cuota y el número de pendientes. Se borra primero el objeto y luego sus
  registros; un error conserva clave y cargo para el siguiente intento.
- Un adjunto cargado por esta vía conserva su cargo al borrar el último
  vínculo, hasta el mismo vencimiento y margen. Esto impide recrear un objeto
  con la URL anterior después de un borrado inmediato.
- El barrido antiguo también conserva imágenes de borrador por 30 días,
  más el margen. Esto supera las URLs anteriores de 48 horas. La cuenta y el
  blob se vuelven a comprobar bajo el lock compartido con los adjuntos.
- Los callbacks de destrucción admiten blobs ausentes: la importación de
  cuentas puede borrar los blobs en bloque antes de destruir sus adjuntos.
  La prueba existente de ida y vuelta lo comprueba.
- No hay pasos manuales: el despliegue normal aplica la migración y usa la
  tarea periódica. El cambio no tiene efecto visual.

## Qué no pude comprobar

No ejecuté MySQL, el entorno SaaS completo ni PUT contra S3. La concurrencia
se comprobó con SQLite. En el código instalado de Active Storage, S3 firma
`content_length` y checksum; Disk valida ambos y se probó por HTTP. No se
prueba aquí una carga que siga activa más de una hora después de vencer la URL:
ese margen limita la espera antes de borrar. No ejecuté pruebas de sistema,
porque el cambio no toca vistas.

## Autoría de los casos de la primera revisión

Antes de editar: se agregan `uploaded draft remains usable after a long pause`,
`legacy uploaded draft is not deleted after a weekend` y `detaching imported
upload metadata does not require the original identity`.

- **Contrato:** conservar una imagen en un borrador durante pausas normales y
  permitir quitar adjuntos importados cuyo autor no existe en este servidor.
  Fronteras: limpieza real, adjunto ActionText y destrucción de adjunto.
- **Regresión:** usar la duración de la URL como plazo del borrador lo elimina
  durante una pausa; exigir una identidad antigua en la reserva revierte el
  borrado del adjunto importado.
- **Cobertura:** los casos iniciales sólo cubren adjuntos inmediatos y autores
  de este servidor. No había prueba de un borrador tras una pausa ni de metadata
  de un autor que no existe.
- **Seam:** ninguno. Se usan blobs, limpieza y adjuntos productivos. Una metadata
  con UUID de identidad ausente representa el dato que copia la importación.
  La base de estos casos es el primer commit de la tarjeta, `dbef2d0f4f15e62505ea089c8681a64dae1a6245`.


### RED de la primera revisión y GREEN final

Se exportó ese SHA con `git archive` a `.context/fizzy-779-review-red` y se
copió la prueba candidata. Mismo entorno Ruby/mise/OSS que el RED inicial:

```bash
mise exec -- bash -c 'cd ../.context/fizzy-779-review-red && bin/rails test test/models/storage/upload_reservation_test.rb --name "/draft|imported/"'
```

RED: salida 1, tres casos, tres aserciones, dos fallos y un error por el defecto
real. Se eliminan las dos imágenes de borrador y el borrado del adjunto importado
falla con `Identity must exist`. No hay error de entorno ni tabla ausente.

La limpieza conserva ahora borradores subidos por 30 días. Se retiró el rechazo
por fecha al adjuntar; el lock y la comprobación del blob siguen evitando la
carrera contra la limpieza. La relación con identidad es opcional, porque la
cuota del borrado pertenece a la cuenta y el autor importado puede no existir.

Los casos añadidos de carga fallida y borrador abandonado usan el contrato de
limpieza de la ficha inicial: distinguen un PUT que nunca creó un objeto del
archivo subido conservado para el editor. No agregan un seam.

GREEN final: `PARALLEL_WORKERS=4 mise exec -- bin/rails test`, con el entorno
completo anterior: salida 0; **1.823 casos, 7.178 aserciones, cero fallos, cero
errores, seis omisiones**. El lote enfocado de cargas HTTP y almacenamiento:
120 casos, 387 aserciones, salida 0. RuboCop de los tres archivos Ruby de esta
ronda y `git diff --check`: salida 0.


El mismo selector `--name "/draft|imported/"` en el checkout corregido devuelve
salida 0: cuatro casos y 14 aserciones. Son los tres casos del RED más el nuevo
caso de vencimiento del borrador a los 30 días.
