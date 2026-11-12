# Mapa de trabajo (Handy #2348)

El mapa de trabajo es una vista de sólo lectura de Fizzy, en `/{cuenta}/work_map`.
Muestra en un solo grafo las tarjetas, las dependencias y las esperas de todos
los productos que la persona puede ver. Desde el mapa no se cambia nada.

## Fuentes y autoridad

- **Fizzy** da la identidad: tablero, número, título, columna y disposición
  (Maybe?, columna, Not Now, cerrada). Fizzy sólo muestra tarjetas que
  `User#accessible_cards` permite.
- **Dédalo** da la ejecución: el estado del trabajo, la espera, los hitos
  (integrada, desplegada, publicada) y las dependencias entre tarjetas. Dédalo
  conserva la autoridad. Fizzy no guarda una copia: lee el grafo cuando
  alguien abre el mapa, con un caché corto.
- No hay otra base de dependencias, ni un supervisor nuevo, ni consultas por
  tarjeta. Fizzy hace una sola petición agregada para todos los productos.

## Contrato de lectura (Dédalo → Fizzy), versión 1

Fizzy hace `GET` a la dirección de `WORK_MAP_SOURCE_URL`, con
`Authorization: Bearer <token>`. El token está en el archivo de
`WORK_MAP_SOURCE_TOKEN_FILE`. Si falta alguna de las dos, el mapa muestra
«Fuente de ejecución no configurada» y sólo los datos de Fizzy.

Límites del lado de Fizzy: 5 s de plazo total, 2 MiB de respuesta, 5000
elementos y 5000 relaciones. Un valor fuera de contrato se descarta; un objeto
con una clave desconocida se descarta entero. Fizzy guarda la respuesta 30 s.

```json
{
  "schema": 1,
  "generated_at": "2026-11-12T19:00:00Z",
  "products": [
    { "id": "handy", "name": "Handy a Bordo", "board_id": "03gx18ixi5yu0txsfh4qcgcjc",
      "status": "ok", "read_at": "2026-11-12T19:00:00Z", "error": null, "truncated": false }
  ],
  "items": [
    { "product": "handy", "card": 2348, "state": "held",
      "wait": { "kind": "card", "reason": "Necesita la ruta de lectura de Dédalo",
                "since": "2026-11-12T19:30:00Z", "checked_at": "2026-11-12T19:45:00Z",
                "human": "not_required", "next_step": "Rebase y verificar el mapa" },
      "milestones": { "integrated_at": null, "deployed_at": null, "published_at": null } }
  ],
  "relations": [
    { "prerequisite": { "product": "dedalo", "card": 2400 },
      "dependent": { "product": "handy", "card": 2348 },
      "condition": "integration", "environment": "integration", "channel": "main",
      "status": "pending", "since": "2026-11-12T19:30:00Z", "resolved_at": null }
  ]
}
```

Campos permitidos y valores:

- `products[]`: el registro vigente de Dédalo. `id` es `[a-z0-9-]{1,40}`.
  `status` es `ok`, `partial` o `failed`. `error` es un código corto
  `[a-z0-9_]{1,60}` o `null`, nunca un mensaje ni una ruta. `truncated: true`
  dice que Dédalo no envió todo el inventario del producto.
- `items[]`: una tarjeta con datos de ejecución. `state` es el estado de
  Dédalo (`[a-z_]{1,40}`). `wait` es `null` si la tarjeta no espera.
  `wait.kind` es `card`, `human`, `resource`, `window`, `deployment`,
  `publication` u `other`. `wait.human` es `required`, `pending`,
  `not_required` o `unknown`. `reason` y `next_step` tienen hasta 280
  caracteres. Las fechas son ISO 8601 o `null`; Fizzy nunca inventa una.
- `relations[]`: una flecha de prerrequisito a dependiente. `condition` es
  `integration`, `qa`, `publication`, `installed`, `landing` u `other`.
  `status` es `pending` (vigente), `satisfied` (cumplida con evidencia),
  `reconciled` (cumplida por otra tarjeta, p. ej. una duplicada) o `ended`
  (el prerrequisito terminó sin cumplir). Cerrar una tarjeta no la cumple.
  `environment` y `channel` son opcionales (`[a-z0-9_.-]{1,40}`).

Dédalo nunca envía tokens, claims, prompts, comentarios, rutas de worktree,
sesiones ni metadata cruda. Envía datos de todos los productos de la máquina;
Fizzy es quien filtra por los permisos de cada persona.

## Permisos y privacidad

- El producto de una tarjeta es el producto de Dédalo cuyo `board_id` es el
  tablero de la tarjeta. Sin la fuente, el tablero hace de producto.
- Un elemento o una relación cuyo extremo está en un tablero sin acceso, o en
  una tarjeta que la persona no puede ver, no muestra su producto, su número
  ni su título: aparece como «Tarjeta sin acceso». Una tarjeta que no existe
  en un tablero con acceso aparece como «Referencia ausente».
- Un producto sin tablero accesible no aparece, ni en la cobertura.
- El navegador recibe sólo los campos de esta lista, ya filtrados.

## Qué muestra por defecto

Todas las tarjetas abiertas (Maybe?, columnas, Not Now) de los tableros
accesibles, y las cerradas que son extremo de una relación. Una tarjeta con
datos de Dédalo muestra su estado; una sin datos muestra «Sin información de
ejecución», que no es lo mismo que «Sin bloqueos». Hasta 3000 tarjetas; si hay
más, el mapa lo dice.

## Activación

Hoy Dédalo no tiene la ruta de lectura: la pide
[Dédalo #2369](https://hermes.tailbaa835.ts.net:43008/1/cards/2369). Sin
`WORK_MAP_SOURCE_URL` el mapa ya funciona con los datos de Fizzy y dice
«fuente no configurada». Cuando la ruta esté instalada:

1. Pon `WORK_MAP_SOURCE_URL` en el archivo de entorno del Fizzy local
   (`FIZZY_LOCAL_ENV_FILE` en `docker-compose.fizzy-local.yml` del workspace).
2. Monta el token como secreto del contenedor y pon su ruta en
   `WORK_MAP_SOURCE_TOKEN_FILE`. Nunca pongas el token en el archivo de entorno.
3. Abre el mapa y confirma la marca «Ejecución de Dédalo generada …» y la
   cobertura de cada producto.

`WORK_MAP_SOURCE_FILE` lee un JSON de ejemplo en lugar de Dédalo. Sólo
funciona en desarrollo y en pruebas; producción lo ignora.

## Rendimiento medido

Ensayo con datos sintéticos (no son datos reales): 5 tableros, 3000 tarjetas
abiertas visibles, 902 tarjetas con ejecución y 3008 relaciones, en modo
desarrollo de esta máquina el 12 de noviembre de 2026.

- Página: 1,37 MB sin comprimir. Servidor: 1,1 s (17 consultas, sin N+1).
  Página lista en el navegador: 1,5 a 1,7 s.
- Diseño del grafo (JS): unos 40 ms para 3000 tarjetas y 3000 relaciones.
- Filtro: 0,1 s. Restablecer filtros (redibuja todo): 0,8 s. Selección: 0,15 s.

Falta el ensayo con datos reales saneados: necesita la ruta de Dédalo #2369.

## Pruebas

`test/models/work_map_test.rb`, `test/models/work_map/source_test.rb`,
`test/controllers/work_maps_controller_test.rb`,
`test/javascript/work_map_graph_test.mjs` y `test/system/work_map_test.rb`.
