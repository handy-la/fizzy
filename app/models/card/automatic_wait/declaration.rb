# The only writer of automatic waits. It validates a bounded body, then decides
# under the card's fence lock: the epoch must be current, the expected revision
# must match (compare-and-swap), the owner must match or hand over explicitly,
# and the run may only move forward. A retry of a write that already applied is
# answered with the stored row instead of a conflict. Ordering never trusts the
# client's clock: it rests on epoch, revision and run sequence; client dates are
# only bounded against the server's clock, and a past valid_until is stored as
# expired evidence, never renewed.
#
# Contract and codes: docs/automatic-waits.md.
class Card::AutomaticWait::Declaration
  Result = Data.define(:status, :code, :wait, :details) do
    def success? = status.in?(%i[ created updated replayed cleared ])
  end

  MAX_BODY_BYTES = 8.kilobytes
  MAX_ACTIVE_PER_CARD = 20
  MAX_ROWS_PER_CARD = 100
  MAX_HORIZON = 24.hours
  CLOCK_SKEW = 1.minute
  MAX_INTEGER = 2**53 - 1
  MAX_TEXT = 200

  KEY_FORMAT = /\A[a-z0-9][a-z0-9._:-]{0,63}\z/
  IDENTIFIER_FORMAT = /\A[a-z0-9][a-z0-9._:-]{0,99}\z/
  # The time stamp form JSON producers emit: date, time and an explicit offset.
  TIME_FORMAT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?(Z|[+-]\d{2}:\d{2})\z/

  # Free text is shown on a card. A secret, a token or a command does not
  # belong there; these catch the common shapes, and the producer stays
  # responsible for the rest (docs/automatic-waits.md).
  SENSITIVE_TEXT = [
    /[[:cntrl:]]/,
    /[`$|;<>\\{}]/,
    %r{://[^/\s]*@}i,
    /\b(bearer|basic)\s+\S/i,
    /\b(token|password|passwd|secret|api[_-]?key|authorization)\b\s*[:=]/i,
    /\b(gh[pousr]_|github_pat_|sk-|xox[abpr]-|AKIA|ASIA|glpat-)/
  ].freeze

  DECLARE_ATTRIBUTES = %w[
    epoch expected_revision owner replaces_owner run_id run_sequence
    producer state reason expected_event next_check_at valid_until human_condition
  ].freeze
  DECLARE_REQUIRED = (DECLARE_ATTRIBUTES - %w[ replaces_owner next_check_at ]).freeze
  CLEAR_ATTRIBUTES = %w[ epoch expected_revision owner run_id run_sequence ].freeze

  class << self
    def declare(card:, key:, body:, user:, now: Time.current)
      new(card: card, key: key, body: body, user: user, now: now).declare
    end

    def clear(card:, key:, body:, user:, now: Time.current)
      new(card: card, key: key, body: body, user: user, now: now).clear
    end
  end

  def initialize(card:, key:, body:, user:, now:)
    @card, @key, @body, @user, @now = card, key, body, user, now
  end

  def declare
    errors = validate_shape(DECLARE_ATTRIBUTES, DECLARE_REQUIRED)
    errors.concat(validate_declaration) if errors.empty?
    return invalid(errors) if errors.any?

    serialize do |fence|
      wait = @card.automatic_waits.find_by(key: @key)

      # A retry is recognised before the clock bounds, which belong to a new
      # write: its dates may have passed since the write it repeats applied.
      if wait&.active? && wait.request_digest == digest && wait.revision == @body["expected_revision"] + 1 && wait.epoch == fence.epoch
        next result(:replayed, wait)
      end

      time_errors = validate_time_ranges
      next invalid(time_errors) if time_errors.any?

      next conflict(:card_closed) if card_closed?
      next conflict(:epoch_mismatch, fence: fence) unless @body["epoch"] == fence.epoch
      next conflict(:revision_mismatch, wait: wait) unless @body["expected_revision"] == (wait&.revision || 0)

      if wait
        refusal = refuse_takeover(wait) || refuse_reactivation(wait)
        next refusal if refusal
      elsif (limit = refuse_new_key)
        next limit
      end

      write_declaration(wait || @card.automatic_waits.new(key: @key), fence)
    end
  end

  def clear
    errors = validate_shape(CLEAR_ATTRIBUTES, CLEAR_ATTRIBUTES)
    errors.concat(validate_run) if errors.empty?
    return invalid(errors) if errors.any?

    serialize do |fence|
      wait = @card.automatic_waits.find_by(key: @key)
      next result(:not_found, nil, code: :wait_not_found) unless wait

      if wait.cleared? && wait.request_digest == digest && wait.revision == @body["expected_revision"] + 1
        next result(:replayed, wait)
      end

      next conflict(:epoch_mismatch, fence: fence) unless @body["epoch"] == fence.epoch
      next conflict(:revision_mismatch, wait: wait) unless @body["expected_revision"] == wait.revision
      next conflict(:owner_mismatch, wait: wait) unless @body["owner"] == wait.owner
      # A wait the card retired can still be cleared by its owner: it may keep a
      # human condition on view, and the clear is what takes it off the card.
      next conflict(:already_retired, wait: wait) if wait.cleared?
      next conflict(:stale_run, wait: wait) if @body["run_sequence"] < wait.run_sequence
      next conflict(:run_conflict, wait: wait) if @body["run_sequence"] == wait.run_sequence && @body["run_id"] != wait.run_id

      wait.update!(retired_at: @now, retired_reason: "cleared", run_id: @body["run_id"], run_sequence: @body["run_sequence"],
        revision: wait.revision + 1, request_digest: digest, declared_by: @user)
      result(:cleared, wait)
    end
  end

  private
    def serialize
      Card::AutomaticWait.transaction do
        yield Card::AutomaticWait::Fence.lock_for(@card)
      end
    end

    def card_closed?
      Closure.exists?(card_id: @card.id)
    end

    # The owner hands over only by naming the owner it replaces, and a new run
    # must be newer than every run the row has seen, retired ones included.
    def refuse_takeover(wait)
      if @body["owner"] != wait.owner
        return conflict(:owner_mismatch, wait: wait) unless @body["replaces_owner"] == wait.owner
        return conflict(:stale_run, wait: wait) unless @body["run_sequence"] > wait.run_sequence
      elsif @body.key?("replaces_owner")
        return conflict(:owner_mismatch, wait: wait)
      end

      if wait.retired?
        conflict(:retired_run, wait: wait) unless @body["run_sequence"] > wait.run_sequence
      elsif @body["run_sequence"] < wait.run_sequence
        conflict(:stale_run, wait: wait)
      elsif @body["run_sequence"] == wait.run_sequence && @body["run_id"] != wait.run_id
        conflict(:run_conflict, wait: wait)
      end
    end

    # Declaring a tombstone again makes it active, so it counts like a new key.
    def refuse_reactivation(wait)
      conflict(:too_many_waits) if wait.retired? && @card.automatic_waits.active.count >= MAX_ACTIVE_PER_CARD
    end

    def refuse_new_key
      if @body.key?("replaces_owner")
        conflict(:owner_mismatch)
      elsif @card.automatic_waits.active.count >= MAX_ACTIVE_PER_CARD || @card.automatic_waits.count >= MAX_ROWS_PER_CARD
        conflict(:too_many_waits)
      end
    end

    def write_declaration(wait, fence)
      created = wait.new_record?

      wait.assign_attributes(
        board_id: @card.board_id, declared_by: @user, epoch: fence.epoch,
        revision: created ? 1 : wait.revision + 1, request_digest: digest,
        retired_at: nil, retired_reason: nil,
        owner: @body["owner"], run_id: @body["run_id"], run_sequence: @body["run_sequence"],
        producer: @body["producer"], state: @body["state"],
        reason: @body["reason"], expected_event: @body["expected_event"],
        next_check_at: parse_time(@body["next_check_at"]), valid_until: parse_time(@body["valid_until"]),
        human_condition: @body["human_condition"])
      wait.save!

      result(created ? :created : :updated, wait)
    end

    # ---- Validation of the body, before any lock ----

    def validate_shape(allowed, required)
      return [ error(:body, :not_an_object) ] unless @body.is_a?(Hash)

      errors = []
      errors << error(:key, :invalid_format) unless @key.is_a?(String) && @key.match?(KEY_FORMAT)
      (@body.keys - allowed).sort.each { |name| errors << error(name, :unknown_property) }
      (required - @body.keys).each { |name| errors << error(name, :missing) }
      errors
    end

    def validate_run
      errors = []
      %w[ epoch expected_revision ].each { |name| errors << error(name, :invalid_integer) unless integer?(@body[name], min: 0) }
      errors << error("run_sequence", :invalid_integer) unless integer?(@body["run_sequence"], min: 1)
      %w[ owner run_id ].each { |name| errors << error(name, :invalid_format) unless identifier?(@body[name]) }
      errors
    end

    def validate_declaration
      errors = validate_run

      if @body.key?("replaces_owner") && !identifier?(@body["replaces_owner"])
        errors << error("replaces_owner", :invalid_format)
      end

      states = Card::AutomaticWait::PRODUCER_STATES[@body["producer"]]
      if states.nil?
        errors << error("producer", :unknown_value)
      elsif !states.include?(@body["state"])
        errors << error("state", :unknown_value)
      end

      errors << error("human_condition", :unknown_value) unless @body["human_condition"].in?(Card::AutomaticWait::HUMAN_CONDITIONS)
      %w[ reason expected_event ].each { |name| errors.concat(validate_text(name)) }
      errors.concat(validate_time_formats)
    end

    def validate_text(name)
      value = @body[name]
      if !value.is_a?(String) || value.strip.empty? || value.length > MAX_TEXT || value != value.strip
        [ error(name, :invalid_text) ]
      elsif SENSITIVE_TEXT.any? { value.match?(it) }
        [ error(name, :sensitive_text) ]
      else
        []
      end
    end

    def validate_time_formats
      errors = []
      errors << error("valid_until", :invalid_date) unless parse_time(@body["valid_until"])
      if !@body["next_check_at"].nil? && parse_time(@body["next_check_at"]).nil?
        errors << error("next_check_at", :invalid_date)
      end
      errors
    end

    # Bounds against the server's clock, checked under the lock and only for a
    # write that is not a retry. A missing next_check_at is an event-only wait.
    #
    # A valid_until already past is expired evidence, kept with its original
    # date: the wait is stale from the first write, and a producer can still
    # update its human condition without renewing a report the monitor never
    # made (Handy #2314). Only the future is bounded, so a date can never claim
    # more validity than the horizon. A next check of expired evidence is only
    # bounded by that evidence.
    def validate_time_ranges
      valid_until = parse_time(@body["valid_until"])
      next_check_at = parse_time(@body["next_check_at"]) unless @body["next_check_at"].nil?
      expired = valid_until <= @now

      errors = []
      errors << error("valid_until", :out_of_range) if valid_until > @now + MAX_HORIZON
      if next_check_at && (next_check_at > valid_until || (!expired && next_check_at < @now - CLOCK_SKEW))
        errors << error("next_check_at", :out_of_range)
      end
      errors
    end

    # Time.iso8601 rolls 30 February over to March: a date that does not read
    # back the same is invalid, not normalised.
    def parse_time(value)
      return unless value.is_a?(String) && value.match?(TIME_FORMAT)

      time = Time.iso8601(value)
      time.utc if time.strftime("%Y-%m-%dT%H:%M:%S") == value[0, 19]
    rescue ArgumentError
      nil
    end

    def integer?(value, min:)
      value.is_a?(Integer) && value >= min && value <= MAX_INTEGER
    end

    def identifier?(value)
      value.is_a?(String) && value.match?(IDENTIFIER_FORMAT)
    end

    # The body that produced the row, without the revision it was based on, so
    # a retry of the same write is recognised whatever revision it read.
    def digest
      @digest ||= begin
        canonical = @body.except("expected_revision").sort.to_h
        canonical["next_check_at"] = parse_time(canonical["next_check_at"])&.iso8601(6) if canonical.key?("next_check_at")
        canonical["valid_until"] = parse_time(canonical["valid_until"])&.iso8601(6) if canonical.key?("valid_until")
        Digest::SHA256.hexdigest([ @key, canonical ].to_json)
      end
    end

    def error(attribute, code)
      { attribute: attribute.to_s, code: code.to_s }
    end

    def invalid(errors)
      result(:invalid, nil, code: :invalid, details: errors)
    end

    def conflict(code, wait: nil, fence: nil)
      details = {}
      details[:revision] = wait.revision if wait
      details[:epoch] = (fence || Card::AutomaticWait::Fence.for(@card)).epoch
      result(:conflict, wait, code: code, details: details)
    end

    def result(status, wait, code: status, details: nil)
      Result.new(status: status, code: code, wait: wait, details: details)
    end
end
