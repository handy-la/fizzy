# Handy #371 — ficha de autoría y RED de las pruebas

Política: `test-audit` del poly-repo de Handy. Esta ficha cubre cada prueba
nueva o modificada por la tarjeta. No retira ninguna prueba ni seam.

## Evidencia RED y GREEN

- **Base funcional (sin ninguna mejora):** `1b7ba7374357a63b9bceb9d3edb37fa6ea9346c2`
  (merge de basecamp/fizzy, antes del primer commit de la tarjeta).
- **Base del defecto de la barra flotante:** `ce8f32e4d72871a4c45e5a3b74eab2aa3e415df9`
  (la barra observaba `.card-perma__bg`, la tarjeta entera).
- **GREEN:** `d7d79c69e60fd97b015b5cd9d06a94167a31bc29`.
- **Método RED:** `git archive <base> | tar -x` en un directorio temporal
  aislado (scratchpad de la sesión, fuera de todo worktree), copia de las
  pruebas de la tarjeta encima, y en ese directorio:
  `SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 mise exec -- bin/rails test <archivo>`
  (Ruby 3.4.8 de mise, SQLite, variables de RVM/Bundler removidas). Mismo
  comando, sin `PARALLEL_WORKERS`, para GREEN en el checkout de la tarjeta.

| Prueba | RED en la base (exit 1) | Causa del RED | GREEN |
|---|---|---|---|
| `test/models/card/watchable_test.rb` | 3 tests, 1 failure | `Expected true to be nil or false`: la base suscribe al creador | pasa |
| `test/models/card/commentable_test.rb` | 3 tests, 1 failure | `Expected true to be nil or false`: la base suscribe a quien comenta | pasa |
| `test/controllers/notifications/trays_controller_test.rb` | 5 tests, 2 failures | no hay `a.card--notification[style*="--card-color: …"]`: el atributo `style` no se generaba | pasa |
| `test/integration/header_board_links_test.rb` | 4 tests, 3 failures | 0 elementos `.header__board-link` | pasa |
| `test/integration/card_dock_test.rb` | 7 tests, 6 failures | 0 elementos `.card-dock` / `.approval-toast` | pasa |
| `test/models/column/approval_test.rb` | 2 tests, 2 errors | `NoMethodError: awaiting_approval?` / `next_card_awaiting` en `Column` | pasa |
| `test/models/leaderboard_test.rb` | 6 tests, 6 errors | `NameError: uninitialized constant Leaderboard` | pasa |
| `test/controllers/leaderboards_controller_test.rb` | 2 tests, 2 errors | `NameError: leaderboard_path` (sin ruta) | pasa |
| `test/system/card_dock_test.rb` (base `ce8f32e4`) | 2 tests, 2 failures | `expected to find css ".card-dock--visible"` con el cuerpo de la tarjeta aún visible | pasa |

Los `NameError`/`NoMethodError` de la tabla no son un import roto de la
prueba: la clase, el método y la ruta son la función nueva que la base no
tiene. En cada archivo, las pruebas que pasan en la base son guardas del
alcance (por ejemplo, «no hay aviso al mover hacia atrás»), no el RED.

GREEN en `d7d79c69`: los ocho archivos de unidad/integración, 32 tests, 0
failures; el de sistema, 2 tests, 0 failures. Suite completa
`bin/rails test`: 0 failures; `bin/rails test:system`: 0 failures.

Sin prueba automática, verificado a mano en el navegador: la animación del
contador (`count_up_controller.js`) y el confeti; son cosméticos y los totales
los prueba el HTML del servidor.

## Las cuatro respuestas por contrato

### Suscripción manual (watchable_test, commentable_test — casos modificados)

1. **Contrato:** crear una tarjeta o comentarla no crea un `Watch` activo del
   autor. Dueño: `Card::Watchable`, `Comment`. Frontera: `Card#watched_by?`.
2. **Regresión:** volver a agregar `after_create :subscribe_creator` o
   `after_create_commit :watch_card_by_creator`.
3. **Cobertura:** los dos casos existentes afirmaban lo contrario; se
   invierten en lugar de agregar otros. Menciones (`mentions_test.rb`) y
   asignaciones (`assignable_test.rb`) siguen cubiertas y sin cambio.
4. **Seam:** no requiere uno.

### Color de la notificación (trays_controller_test — dos casos nuevos)

1. **Contrato:** cada notificación de la bandeja lleva en `style` el
   `--card-color` de la columna de su tarjeta, también tras cambiar de columna
   con la caché de colección activa. Dueño: `NotificationsHelper#notification_tag`
   y las vistas `notifications/*`. Frontera: el HTML de `GET /notifications/tray`.
2. **Regresión:** volver al hash `style: { "--card-color:": … }` (no genera el
   atributo), o quitar la tarjeta de la llave de caché (color viejo).
3. **Cobertura:** `trays_controller_test.rb` sólo comprobaba el texto y el
   JSON; nada miraba el color. El segundo caso usa
   `with_actionview_partial_caching`, porque en pruebas la caché es `null_store`.
4. **Seam:** no requiere uno.

### Enlaces a tableros (header_board_links_test — nuevo)

1. **Contrato:** la barra superior enlaza a los tableros accesibles del
   usuario, sin repetir el tablero actual ni el de la tarjeta abierta, y nunca
   a un tablero sin acceso. Dueño: `My::BoardLinksHelper`, layout. Frontera: HTML.
2. **Regresión:** quitar el parcial del layout, no excluir el tablero actual,
   o listar `Board.all` en lugar de `Current.user.boards`.
3. **Cobertura:** ninguna prueba cubría el encabezado; el menú (`my/menus`) es
   otra vista cargada aparte.
4. **Seam:** no requiere uno.

### Barra flotante, DONE arriba en móvil y aviso de aprobación (card_dock_test, approval_test, system/card_dock_test — nuevos)

1. **Contrato:** la página de una tarjeta abierta trae la barra con DONE y la
   etapa anterior y siguiente del tablero (Maybe? antes de la primera columna);
   una tarjeta cerrada sólo ofrece deshacer DONE; la cabecera trae DONE para
   móvil sólo si está abierta; avanzar desde la barra fuera de AWAITING APPROVAL
   ofrece la siguiente tarjeta de esa etapa o avisa que no queda ninguna, y no
   ocurre al retroceder ni sin `from=dock`. En el navegador, la barra aparece al
   salir la cabecera con el cuerpo aún visible y DONE cambia su estado.
   Dueños: `CardDockHelper`, `Cards::TriagesController`, `Column::Approval`,
   `card_dock_controller.js`. Fronteras: HTML, redirección + flash, navegador.
2. **Regresión:** errar el vecino de columna, perder `from: "dock"`, mostrar el
   aviso en cualquier movimiento, comparar el nombre sin normalizar, o
   observar otra vez la tarjeta entera (el defecto que halló la revisión).
3. **Cobertura:** `triages_controller_test.rb` sólo prueba el cambio de columna
   y la redirección; `positioned_test.rb`, el orden de columnas. Ninguna mira
   la barra ni el aviso. La prueba de sistema tiene riesgo propio: la
   visibilidad es JavaScript (IntersectionObserver), invisible en integración.
4. **Seam:** `params[:from] == "dock"` es entrada productiva de la barra
   (consumidor: `_dock.html.erb`), no un seam de prueba.

### Leaderboard (leaderboard_test, leaderboards_controller_test — nuevos)

1. **Contrato:** una tarjeta cuenta una vez como enviada, en su primera
   llegada a DEPLOYED o PUBLISHED (eventos `card_triaged`, o su columna actual
   si no hay evento), sólo en tableros accesibles; DONE cuenta cerradas; racha,
   meta, mejor día, gráfica diaria, tableros y personas salen de esos datos; la
   página lo muestra y el menú la enlaza. Dueño: `Leaderboard`,
   `LeaderboardsController`. Fronteras: el modelo y el HTML.
2. **Regresión:** contar cada evento en lugar de la tarjeta, tomar la última
   llegada, ignorar el acceso por tablero, o romper el corte de la racha.
3. **Cobertura:** función nueva; no hay pruebas previas.
4. **Seam:** `Leaderboard.new(user, now:)` recibe `now` para fijar el día; su
   consumidor productivo es el controlador (usa el valor por omisión).
