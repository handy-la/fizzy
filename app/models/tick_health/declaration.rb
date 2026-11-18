class TickHealth::Declaration
  FIELDS = %w[ schema expected_revision product_id run_id run_sequence state phase phase_started_at reported_at valid_until next_run_at expected_event last_result last_finished_at last_reason duration_min_seconds duration_max_seconds duration_samples ].freeze
  DATES = %w[ phase_started_at reported_at valid_until next_run_at last_finished_at ].freeze
  ACTIVE = %w[ running waiting_ci waiting_resource ].freeze
  Result = Data.define(:status, :code, :details)

  def self.write(board:, stage_id:, body:, user:, now: Time.current)
    new(board, stage_id, body, user, now).write
  end

  def initialize(board, stage_id, body, user, now)
    @board, @stage_id, @body, @user, @now = board, stage_id, body, user, now
  end

  def write
    registry = TickHealth::Registry.for(@board)
    stage = registry&.fetch("stages")&.find { it["id"] == @stage_id }
    return result(:not_found, :not_configured) unless stage && @board.columns.exists?(id: stage["column_id"], account_id: @board.account_id)
    return result(:forbidden, :producer_mismatch) unless registry["producer_user_id"] == @user.id
    errors = validate(registry)
    return result(:unprocessable_entity, :invalid, errors) if errors.any?

    TickHealth.transaction do
      # An UPDATE takes the write lock before reading, also on SQLite. No touch
      # or broadcast of cards: health has its own channel.
      Board.where(id: @board.id).update_all("id = id")
      row = TickHealth.find_by(board: @board, stage_id: @stage_id)
      digest = Digest::SHA256.hexdigest(@body.except("expected_revision").sort.to_h.to_json)
      if row && row.request_digest == digest && row.revision == @body["expected_revision"] + 1
        next result(:ok, :replayed)
      end
      next result(:conflict, :revision_mismatch, revision: row&.revision || 0) unless @body["expected_revision"] == (row&.revision || 0)
      if row
        next result(:conflict, :product_mismatch) unless row.product_id == registry["id"]
        next result(:conflict, :stale_run) if @body["run_sequence"] < row.evidence["run_sequence"]
        if @body["run_sequence"] == row.evidence["run_sequence"]
          next result(:conflict, :run_conflict) unless @body["run_id"] == row.evidence["run_id"]
          next result(:conflict, :stale_report) if date("reported_at") < Time.iso8601(row.evidence["reported_at"])
        end
      end
      created = row.nil?
      row ||= TickHealth.new(board: @board, account: @board.account, stage_id: @stage_id, product_id: registry["id"])
      row.update!(revision: row.revision.to_i + 1, request_digest: digest, evidence: @body.except("expected_revision"))
      result(created ? :created : :ok, created ? :created : :updated)
    end
  end

  private
    def validate(registry)
      return [ error(:body, :not_an_object) ] unless @body.is_a?(Hash)
      unknown = @body.keys - FIELDS
      return unknown.map { error(it, :unknown_property) } if unknown.any?
      missing = FIELDS - @body.keys
      return missing.map { error(it, :missing) } if missing.any?
      errors = []
      errors << error(:schema, :unknown_value) unless @body["schema"].is_a?(Integer) && @body["schema"] == 1
      errors << error(:product_id, :unknown_value) unless @body["product_id"] == registry["id"]
      errors << error(:run_id, :invalid_format) unless @body["run_id"].is_a?(String) && @body["run_id"].match?(TickHealth::Registry::IDENTIFIER)
      { "expected_revision" => 0, "run_sequence" => 1, "duration_samples" => 0 }.each do |key, min|
        errors << error(key, :invalid_integer) unless integer?(@body[key], min, key == "duration_samples" ? 1_000_000 : 2**53 - 1)
      end
      errors << error(:state, :unknown_value) unless @body["state"].in?(TickHealth::STATES)
      errors << error(:last_result, :unknown_value) unless @body["last_result"].nil? || @body["last_result"].in?(TickHealth::RESULTS)
      %w[ phase expected_event last_reason ].each do |key|
        value = @body[key]
        next if value.nil? && key != "phase"
        unless value.is_a?(String) && value.size.between?(1, 200) && value == value.strip && Card::AutomaticWait::Declaration::SENSITIVE_TEXT.none? { value.match?(it) }
          errors << error(key, :invalid_text)
        end
      end
      DATES.each do |key|
        required = key.in?(%w[ reported_at valid_until ]) || (key == "phase_started_at" && @body["state"].in?(ACTIVE))
        errors << error(key, :invalid_date) if (required || !@body[key].nil?) && date(key).nil?
      end
      return errors if errors.any?
      reported = date("reported_at")
      errors << error(:reported_at, :out_of_range) if reported > @now + 60.seconds
      errors << error(:valid_until, :out_of_range) unless date("valid_until").between?(reported, reported + 24.hours)
      %w[ phase_started_at last_finished_at ].each do |key|
        errors << error(key, :out_of_range) if date(key) && date(key) > reported
      end
      errors << error(:next_run_at, :out_of_range) if date("next_run_at") && date("next_run_at") > reported + 30.days
      if @body["state"].in?(%w[ disabled scheduler_missing ]) && @body["next_run_at"]
        errors << error(:next_run_at, :unexpected)
      end
      if @body["state"].in?(%w[ waiting_ci waiting_resource deferred lock_busy ]) && !@body["expected_event"] && !@body["next_run_at"]
        errors << error(:expected_event, :missing)
      end
      if @body["last_result"].nil? != @body["last_finished_at"].nil? || @body["last_result"].nil? != @body["last_reason"].nil?
        errors << error(:last_result, :inconsistent)
      end
      min, max = @body.values_at("duration_min_seconds", "duration_max_seconds")
      unless (min.nil? && max.nil?) || (integer?(min, 0, 86400) && integer?(max, min, 86400) && @body["duration_samples"] >= 5)
        errors << error(:duration_min_seconds, :invalid_range)
      end
      errors
    end

    def date(key)
      value = @body[key]
      return unless value.is_a?(String) && value.match?(Card::AutomaticWait::Declaration::TIME_FORMAT)
      offset = value.match(/([+-])(\d{2}):(\d{2})\z/)
      return if offset && (offset[2].to_i > 23 || offset[3].to_i > 59)
      time = Time.iso8601(value)
      time.utc if time.strftime("%Y-%m-%dT%H:%M:%S") == value[0, 19]
    rescue ArgumentError
      nil
    end

    def integer?(value, min, max)
      value.is_a?(Integer) && value.between?(min, max)
    end

    def error(attribute, code)
      { attribute: attribute.to_s, code: code.to_s }
    end

    def result(status, code, details = nil)
      Result.new(status, code, details)
    end
end
