module TickHealthsHelper
  TICK_LABELS = {
    "scheduled" => "Programado", "running" => "En curso", "waiting_ci" => "Esperando CI",
    "waiting_resource" => "Esperando recurso", "deferred" => "Diferido", "lock_busy" => "Lock ocupado",
    "noop" => "Sin cambios", "failed" => "Último intento fallido", "no_signal" => "Sin señal",
    "scheduler_missing" => "Sin programador", "disabled" => "Deshabilitado"
  }.freeze

  # One monochrome path per state, shared with the browser through Stimulus.
  TICK_ICONS = {
    "scheduled" => "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2M8 4v4l2.5 1.5",
    "running" => "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2M6.5 5l4 3-4 3z",
    "waiting_ci" => "M5 4 2 8l3 4m6-8 3 4-3 4M9 3 7 13",
    "waiting_resource" => "M5 2h6M5 14h6M6 2v3l4 6v3M10 2v3l-4 6v3",
    "deferred" => "M2 5h10M9 2l3 3-3 3M14 11H4m3-3-3 3 3 3",
    "lock_busy" => "M3 7h10v7H3zM5 7V5a3 3 0 0 1 6 0v2M8 10v1",
    "noop" => "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2M5 8l2 2 4-4",
    "failed" => "M8 2 14.5 14h-13zM8 6v3m0 2.5v.1",
    "no_signal" => "M2 2l12 12M2 6a10 10 0 0 1 3-1.5M8 4a10 10 0 0 1 6 2M4 9a6 6 0 0 1 2-1m3.5 0A6 6 0 0 1 12 9M6.5 12a2 2 0 0 1 3 0",
    "scheduler_missing" => "M2 3h12v11H2zM5 1.5v3M11 1.5v3M2 6h12M6 9l4 3m0-3-4 3",
    "disabled" => "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2M6 5v6m4-6v6",
    "stale" => "M8 2a6 6 0 1 0 0 12A6 6 0 0 0 8 2M8 4v4M8 11v.1"
  }.freeze

  def tick_health_for(column)
    @tick_health_snapshots ||= {}
    snapshot = @tick_health_snapshots[column.board_id] ||= TickHealth.snapshot(column.board)
    snapshot[:stages].find { it["column_id"] == column.id }
  end

  def tick_health_label(stage)
    if tick_health_state(stage) == "stale"
      "Desactualizado"
    else
      TICK_LABELS.fetch(stage["state"], "Sin señal")
    end
  end

  def tick_health_state(stage)
    stage["revision"] > 0 && stage["freshness"] == "stale" ? "stale" : stage["state"]
  end
end
