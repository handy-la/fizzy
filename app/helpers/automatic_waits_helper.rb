# Texts of the automatic-wait clock on a card. The browser recomputes the
# time-dependent ones (automatic_wait_controller.js) with the same rules, so
# both must change together. A date is when the producer will look again,
# never a forecast of when the wait ends.
module AutomaticWaitsHelper
  AUTOMATIC_WAIT_HUMAN_TEXT = {
    "required" => "Requiere intervención humana",
    "pending" => "Hay una decisión humana pendiente",
    "stale" => "Seguimiento desactualizado",
    "unknown" => "Sin evidencia sobre intervención humana",
    "not_required" => "No requiere intervención humana"
  }.freeze

  AUTOMATIC_WAIT_WAIT_HUMAN_TEXT = {
    "required" => "Requiere intervención humana",
    "pending" => "Decisión humana pendiente"
  }.freeze

  AUTOMATIC_WAIT_RETIRED_TEXT = {
    "closed" => "Seguimiento retirado: la tarjeta se cerró",
    "reopened" => "Seguimiento retirado: la tarjeta se reabrió",
    "board_changed" => "Seguimiento retirado: la tarjeta cambió de tablero"
  }.freeze

  def automatic_wait_title(summary)
    summary.waiting? ? "Esperando al sistema" : "Seguimiento automático retirado"
  end

  def automatic_wait_human_text(human)
    AUTOMATIC_WAIT_HUMAN_TEXT.fetch(human)
  end

  def automatic_wait_review_text(wait, now: Time.current)
    case wait.review(now)
    when "scheduled" then "Próxima revisión en aproximadamente #{automatic_wait_duration(wait.next_check_at - now)}"
    when "due" then "Revisión pendiente"
    when "overdue" then "Revisión vencida"
    else "Espera: #{wait.expected_event}"
    end
  end

  def automatic_wait_duration(seconds)
    minutes = [ (seconds / 60.0).ceil, 1 ].max
    minutes < 60 ? "#{minutes} min" : "#{(minutes / 60.0).round} h"
  end

  def automatic_wait_label(summary)
    count = summary.waits.size
    "#{automatic_wait_title(summary)}: #{count} #{count == 1 ? "motivo" : "motivos"}. #{automatic_wait_human_text(summary.human)}"
  end
end
