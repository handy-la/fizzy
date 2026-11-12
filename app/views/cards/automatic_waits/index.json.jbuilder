json.result @result.status if @result

json.card do
  json.number @card.number
  json.board_id @card.board_id
  json.closed @card.closed?
end

json.epoch @card.automatic_wait_epoch
json.server_time Time.current.utc.iso8601(6)

json.summary do
  json.waiting @summary.waiting?
  json.human @summary.human
  json.no_human_intervention_required @summary.no_human_intervention_required?
  json.next_check_at @summary.next_check_at&.utc&.iso8601(6)
  json.presented_keys @summary.waits.map(&:key)
end

json.waits @summary.rows, partial: "cards/automatic_waits/automatic_wait", as: :wait
