# Privacidad de borradores: Handy 938

## Autoría antes de editar las pruebas

- **Contrato:** un miembro con acceso al tablero puede consultar y modificar
  sus borradores, pero no los de otro creador. Un administrador con acceso al
  tablero puede gestionar esos borradores por la política existente de
  `User#can_administer_card?`. El acceso al tablero sigue siendo obligatorio.
  Dueños: `User::Accessor`, `CardScoped`, `CardsController`, publicación,
  búsqueda y sugerencias de referencias. Las fronteras son la asociación
  productiva `accessible_cards` y las peticiones HTTP reales, con sesión y
  prefijo de cuenta.
- **Regresión:** retirar el filtro de borradores permite leerlos por número,
  mostrarlos en búsquedas o referencias y modificarlos o publicarlos. Retirar
  el permiso de publicación permite repetir esa operación sobre una tarjeta
  de otro creador ya publicada. Las pruebas comprueban ausencia de datos y de
  cambios persistidos, además de la respuesta HTTP.
- **Cobertura:** `CardsControllerTest` prueba un borrador propio como admin y
  la separación entre tableros; `Cards::DraftsControllerTest` y
  `Cards::PublishesControllerTest` prueban caminos permitidos como admin.
  `SearchesControllerTest` comprueba números de tarjetas publicadas y tableros
  inaccesibles. `Prompts::CardsControllerTest` sólo comprueba una respuesta
  correcta. Ninguno prueba el borrador ajeno en el mismo tablero. Se agrega
  `CardDraftPrivacyTest` para observar la misma política desde todas sus
  entradas. Los casos de `User::AccessorTest` protegen a los consumidores de
  la asociación fuera de HTTP, sin depender de `Current.user`.
- **Seam:** sesiones, rutas, asociación y creación de tarjetas productivas.
  No se agrega una API para pruebas ni se retira cobertura existente.

## Política

La excepción administrativa incluye owner, porque `User#admin?` ya incluye
ese rol. No concede acceso a tableros privados sin un registro de acceso.
La edición colaborativa de tarjetas publicadas conserva su política actual;
la comprobación de administración al editar protege los borradores.

## Evidencia

Base del repo, sin cambios productivos durante RED:
`8ea002d54eb0b5bfa755c75efa5bddb2fd692a72`.

Las pruebas candidatas se ejecutaron antes de editar el código productivo,
directamente sobre esa base en este checkout. No se usó otro worktree.
SHA-256 de los archivos de prueba, iguales en RED y GREEN:

- `test/integration/card_draft_privacy_test.rb`:
  `e39090bd44d0336be6447e75eac1d7fde20721480755558a522a685023ddab2c`.
- `test/models/user/accessor_test.rb`:
  `cb804835f6a333cb4059a7beee7912bf1501c0fa677183e325b4962280891d69`.

Comando idéntico desde `fizzy-custom/`, Ruby 3.4.8 de mise, SQLite OSS:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/integration/card_draft_privacy_test.rb \
  test/models/user/accessor_test.rb
```

- **RED:** salida 1; 16 casos, 105 aserciones, siete fallos, cero errores.
  La lectura devolvió una redirección al borrador en vez de 404. La escritura
  cambió título y descripción. Publicar creó dos eventos y cambió el estado.
  La búsqueda HTML generó un formulario que dirige al borrador y la referencia
  mostró su título y enlace. La asociación incluyó el borrador ajeno.
  Republicar la tarjeta ajena publicada creó un evento nuevo.
- **GREEN:** salida 0; 16 casos, 134 aserciones, cero fallos, errores u omisiones.
  Se comprueban las rutas de lectura, HTML y JSON de búsqueda, referencias,
  rechazo de escritura y publicación sin cambios persistidos. Se comprueban
  además los caminos permitidos del miembro creador y del admin, y el rechazo
  al admin cuando pierde acceso al tablero.

Los logs locales son `.context/handy-938-red.log` y
`.context/handy-938-green.log` en la raíz del workspace. Los resultados
comprobables quedan en este documento para la revisión.

## Validación final y límites

Con el mismo entorno OSS y variables Ruby heredadas retiradas:

- `PARALLEL_WORKERS=4 mise exec -- bin/rails test`: salida 0;
  1.877 casos, 7.490 aserciones, cero fallos y errores, seis omisiones.
- `mise exec -- bin/rubocop -f simple` sobre los seis archivos Ruby
  modificados: salida 0, sin infracciones.
- `git diff --check`: salida 0.

Antes de revisar se hizo rebase sobre `origin/main`
(`36bef7b3258ccb9d30bdd92dc83323490353bfe6`). Se repitió la suite con el
mismo comando y cuatro workers: salida 0; 1.891 casos, 7.583 aserciones,
cero fallos y errores, seis omisiones. Log local:
`.context/handy-938-suite-rebased.log`.

No se ejecutó la variante SaaS, MySQL ni la suite de navegador. No cambia
el marcado, los estilos ni los textos. Las peticiones HTTP de las pruebas
ejercitan la autorización real. No se verificó un despliegue en producción
ni se accedió a borradores de usuarios reales.
