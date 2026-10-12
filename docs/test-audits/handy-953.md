# Recuperación de una admisión de importación sin terminar

## Autoría antes de editar pruebas

Base: `62be5cb60753d317a399dde72ba36bf9556d875c` (handy-943 en `origin/main`).

- **Contrato:** una admisión sin `finished_at` bloquea toda importación nueva
  de su identidad con 429. `Account::Import::Admission#recover` y la tarea
  `imports:recover_admissions` la terminan sólo si tiene más de una hora, no
  tiene un import pendiente o en proceso, y la cuenta reservada no tiene otro
  import activo ni blobs. Un import fallido se recupera por
  `purge_failed_files`, que borra primero y conserva el cargo si el borrado
  falla. Dueño: `Account::Import::Admission`. Frontera: filas SQL reales,
  objetos de Active Storage y el `claim` productivo.
- **Regresión:** liberar por fecha sin comprobar el trabajo o los objetos
  quita el cargo de blobs que aún existen o deja dos trabajos activos; no
  liberar nada deja la identidad en 429 para siempre.
- **Cobertura:** `import_admission_test.rb` cubre la reserva, el presupuesto y
  el límite de intentos, pero no una admisión interrumpida.
  `import_test.rb` cubre el `ensure` de `start` cuando el proceso sigue vivo;
  no cubre un proceso detenido ni la destrucción de la cuenta. Se agrega un
  caso por cada estado que la recuperación debe rechazar o aceptar, en el
  archivo existente de la admisión.
- **Seam:** `recover` es la API operativa; su consumidor productivo es la
  tarea `imports:recover_admissions`. No hay API sólo para pruebas. La
  interrupción se simula al crear la admisión con `claim` y no llamar a
  `finish`, que es el estado exacto que deja un proceso detenido.

## Excepción RED

La base no tiene `recover` ni la tarea: un caso que la llama falla por método
ausente, y eso no es RED. Lo que sí se comprueba en la base es el síntoma: la
primera parte de cada caso (admisión sin terminar ⇒ `claim` rechaza con
`too_many_requests`) pasa igual antes y después del cambio. El riesgo sin
probar en la base es sólo la ruta nueva; se valida con los casos de rechazo
(trabajo activo, blobs restantes, edad, borrado fallido) que deben dejar la
admisión sin terminar y el cargo intacto.

La tarea tiene su propio caso en `test/tasks/imports_recover_admissions_task_test.rb`:
recupera la admisión segura, conserva la reciente, informa cada una y sale con
error. Contrato propio: el operador ve qué admisión no se liberó y por qué.

## Sensibilidad (cambio temporal controlado, revertido)

Base del arreglo y entorno: Ruby de mise, SQLite, desde `fizzy-custom/`:

```bash
env -u GEM_HOME -u GEM_PATH -u MY_RUBY_HOME -u RUBY_VERSION \
  -u RUBYOPT -u RUBYLIB -u BUNDLE_PATH -u BUNDLE_WITH -u BUNDLE_WITHOUT \
  SAAS=false BUNDLE_GEMFILE=Gemfile PARALLEL_WORKERS=1 CI_PROGRESS_BAR=false \
  mise exec -- bin/rails test test/models/account/import_admission_test.rb
```

Se dejó `ensure_recoverable` sólo con la comprobación de edad y se quitó la
ruta de `purge_failed_files` («liberar por fecha»). Salida 1: ocho casos, tres
fallos — import activo, cuenta destruida con blobs y borrado fallido, cada uno
con `NotRecoverable`/`IOError` esperado y no lanzado. Al quitar la edad y la
ruta de `purge_failed_files`, fallan el proceso detenido y el borrado fallido. Se restauró el archivo.

## Evidencia GREEN

- Admisión y tarea: 9 casos, 46 aserciones, salida 0.
- Suite completa, `PARALLEL_WORKERS=4 … mise exec -- bin/rails test`:
  **2.019 casos, 8.410 aserciones, cero fallos, cero errores y seis omisiones**,
  salida 0.
- `bin/rubocop` sobre los cuatro archivos: sin ofensas.
