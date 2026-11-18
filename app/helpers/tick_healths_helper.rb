module TickHealthsHelper
  TICK_LABELS = {
    "scheduled" => "Programado", "running" => "En curso", "waiting_ci" => "Esperando CI",
    "waiting_resource" => "Esperando recurso", "deferred" => "Diferido", "lock_busy" => "Lock ocupado",
    "noop" => "Sin cambios", "failed" => "Último intento fallido", "no_signal" => "Sin señal",
    "scheduler_missing" => "Sin programador", "disabled" => "Deshabilitado"
  }.freeze

  def tick_health_for(column)
    @tick_health_snapshots ||= {}
    snapshot = @tick_health_snapshots[column.board_id] ||= TickHealth.snapshot(column.board)
    snapshot[:stages].find { it["column_id"] == column.id }
  end

  def tick_health_label(stage)
    if stage["revision"] > 0 && stage["freshness"] == "stale"
      "Desactualizado"
    else
      TICK_LABELS.fetch(stage["state"], "Sin señal")
    end
  end
end
