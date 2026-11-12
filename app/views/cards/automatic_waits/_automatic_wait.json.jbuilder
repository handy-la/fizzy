json.key wait.key
json.status wait.status
json.retired_reason wait.retired_reason
json.retired_at wait.retired_at&.utc&.iso8601(6)
json.presented wait.presentable?
json.(wait, :producer, :state, :owner, :run_id, :run_sequence, :reason, :expected_event, :human_condition, :epoch, :revision)
json.next_check_at wait.next_check_at&.utc&.iso8601(6)
json.valid_until wait.valid_until.utc.iso8601(6)
json.review wait.review(@summary.now)
json.freshness wait.stale?(@summary.now) ? "stale" : "current"
json.updated_at wait.updated_at.utc.iso8601(6)
