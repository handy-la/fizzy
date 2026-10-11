# Handy 922: medios externos con acción explícita

## Autoría (antes de editar las pruebas)

- **Contrato:** mostrar contenido de tarjetas, comentarios y actividad no debe
  iniciar cargas de medios externos. Action Text ofrece un enlace con aviso
  y sin referencia de la página; la actividad muestra un aviso dentro del
  enlace que abre la tarjeta. No debe crear enlaces anidados. La CSP de
  la respuesta debe limitar `img-src` y `media-src` a orígenes autorizados.
- **Regresión:** volver a emitir `img/src` o `video/source/src` con una URL
  externa, perder `rel=noreferrer` durante el saneado, aceptar un esquema
  ejecutable o restaurar `https:` en estas directivas viola el contrato.
- **Cobertura:** `ActionTextRenderingTest` sólo comprueba la eliminación de
  `data-action`. `CardsControllerTest` comprueba un adjunto remoto mal formado,
  pero sólo exige HTTP 200. `EventsControllerTest` comprueba filtros y horarios;
  no comprueba los medios. Se amplía la prueba de Action Text para sus vistas
  y la vista de actividad; una prueba de petición observa persistencia,
  comentarios y cabecera CSP, que no observa la prueba de vistas.
- **Seam:** se usan `ActionText::Content#to_s`, las vistas que consume el feed
  y los endpoints reales de tarjetas. No se agrega una API de producción para
  pruebas. El helper nuevo lo consumen las dos vistas de Action Text.

## Diseño

Se elige la opción de acción explícita de la tarjeta. No hay proxy ni descarga
servidora. Los límites de tamaño, tipo, tiempo, redirecciones y red privada de
un proxy no aplican. El usuario abre el recurso en el sitio externo mediante
un enlace que avisa que comparte su conexión. La actividad está dentro de
un enlace a la tarjeta: muestra texto, sin anidar otro enlace externo.
Sólo se aceptan URLs HTTP(S)
absolutas sin credenciales. Los archivos de Active Storage siguen su camino
propio. Una instalación con S3 debe autorizar su origen exacto mediante
`CSP_IMG_SRC` y `CSP_MEDIA_SRC`; no debe permitir todo `https:`.

## Evidencia RED y GREEN

Base del repo: `8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.
Ruby: 3.4.8, seleccionado con mise desde `fizzy-custom/`.
Pruebas aplicadas a la base y al arreglo, SHA-256:

- `test/helpers/action_text_rendering_test.rb`:
  `5ef4400ff4910324bf595206f9283b1fed996d5d79507f53e062cbe3a6e67c38`.
- `test/controllers/cards_controller_test.rb`:
  `871d87192c3440b719d746ebe0ae03e9b9377768b1be8cc21976ce171840533c`.

Se exportó la base con `git archive` a
`../.context/handy-922-red-base.*`, sin usar otro checkout. Se copiaron sólo
las dos pruebas candidatas. Se seleccionó `ruby_bin` mediante
`env -u GEM_HOME -u GEM_PATH -u RUBYOPT mise which ruby` antes de entrar en la
exportación. La primera ejecución no tenía la base de datos preparada;
ese fallo de entorno no cuenta como RED. Se preparó con el mismo Ruby:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT   -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT   SAAS=false BUNDLE_GEMFILE=Gemfile RAILS_ENV=test   "$ruby_bin" bin/rails db:prepare
```

Comando RED, desde esa exportación:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT   -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT   SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false   "$ruby_bin" bin/rails test test/helpers/action_text_rendering_test.rb   test/controllers/cards_controller_test.rb
```

Resultado RED: **50 pruebas, 224 aserciones, 16 fallos, 0 errores, exit 1**.
Los fallos muestran etiquetas `img`, `video` y `source` con las URLs externas;
la petición encuentra dos medios externos que debía excluir. La prueba de
CSP encuentra `https:` en la directiva. Los casos de actividad rechazan las
etiquetas de medios aun cuando Action Text ya descartó un esquema inválido.

Comando GREEN, desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION -u RUBYOPT   -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT   SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false   mise exec -- bin/rails test test/helpers/action_text_rendering_test.rb   test/controllers/cards_controller_test.rb
```

Resultado GREEN: **50 pruebas, 282 aserciones, 0 fallos, 0 errores, exit 0**.
Los registros locales son `.context/handy-922-red-final.log` y
`.context/handy-922-green.log` en la raíz del workspace.

Con el mismo entorno, `PARALLEL_WORKERS=4 mise exec -- bin/rails test`:
**1881 pruebas, 7474 aserciones, 0 fallos, 0 errores, 6 omisiones, exit 0**.
`PARALLEL_WORKERS=1 mise exec -- bin/rails test:system`:
**43 pruebas, 322 aserciones, 0 fallos, 0 errores, 0 omisiones, exit 0**.
RuboCop sobre los cinco archivos Ruby modificados: sin infracciones.

## Comprobación en Chrome

Se sirvió la tarjeta en modo test, con el usuario de fixture Kevin, tema claro
y la misma ventana de 1280 × 577. Un servidor HTTPS de prueba local registró
las peticiones. Se ignoró sólo su certificado autofirmado en el navegador.
No se usaron datos ni credenciales de una cuenta real.

- Base: abrir la tarjeta o la actividad produjo GET de `pixel.png` y
  `clip.mp4`, con referencia de la página.
- Arreglo: abrir y recargar la tarjeta y la actividad produjo cero peticiones
  de medios al servidor externo.
- Insertar una imagen y un video de ese origen HTTPS en el DOM produjo
  violaciones de CSP para `img-src` y `media-src`, sin petición al servidor.
- Pulsar el enlace de imagen abrió una pestaña. El GET inicial no tenía
  `Referer` ni cookies. El favicon posterior sólo refería al propio sitio
  externo, sin referencia de Fizzy.
- La actividad conservó su único enlace a la tarjeta y mostró los dos avisos.

Capturas locales, adjuntas a la tarjeta: `antes-medios-externos.png`,
`despues-medios-externos.png`, `antes-actividad-medios-externos.png` y
`despues-actividad-medios-externos.png` bajo `.context/` del workspace.

## Lo que no pude verificar

No se probó una instalación SaaS/MySQL ni un bucket S3 real. Los orígenes
adicionales que configure un administrador siguen autorizados por la CSP.
La CSP desactivada o en modo de reporte no bloquea etiquetas arbitrarias;
los partials de medios remotos siguen sin emitirlas. La navegación explícita
comparte la conexión y los datos que el navegador tenga para el sitio de
destino; el aviso lo comunica. No hay proxy que envíe credenciales del servidor.

