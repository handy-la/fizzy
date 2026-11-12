# Handy #2348: the execution graph Dédalo answers, read through an allow-list.
# Every object must have exactly the keys of the contract; an object with an
# unknown key, a value out of range or a bad date is dropped whole and counted,
# never repaired. Only the fields listed here can ever reach a browser.
# Contract: docs/work-map.md.
class WorkMap::Snapshot < Data.define(:generated_at, :products, :items, :relations, :dropped, :over_limit)
  class Invalid < StandardError; end

  SCHEMA = 1
  MAX_PRODUCTS = 200
  MAX_ITEMS = 5_000
  MAX_RELATIONS = 5_000
  TEXT_LIMIT = 280

  PRODUCT_ID = /\A[a-z0-9][a-z0-9-]{0,39}\z/
  BOARD_ID = /\A[a-z0-9]{1,40}\z/
  STATE = /\A[a-z_]{1,40}\z/
  ERROR_CODE = /\A[a-z0-9_]{1,60}\z/
  SCOPE = /\A[a-z0-9_.-]{1,40}\z/

  PRODUCT_STATUSES = %w[ ok partial failed ].freeze
  WAIT_KINDS = %w[ card human resource window deployment publication other ].freeze
  HUMAN_CONDITIONS = %w[ required pending not_required unknown ].freeze
  CONDITIONS = %w[ integration qa publication installed landing other ].freeze
  RELATION_STATUSES = %w[ pending satisfied reconciled ended ].freeze

  TOP_KEYS = %w[ schema generated_at products items relations ].freeze
  PRODUCT_KEYS = %w[ id name board_id status read_at error truncated ].freeze
  ITEM_KEYS = %w[ product card state wait milestones ].freeze
  WAIT_KEYS = %w[ kind reason since checked_at human next_step ].freeze
  MILESTONE_KEYS = %w[ integrated_at deployed_at published_at ].freeze
  RELATION_KEYS = %w[ prerequisite dependent condition environment channel status since resolved_at ].freeze
  ENDPOINT_KEYS = %w[ product card ].freeze
  REQUIRED_RELATION_KEYS = %w[ prerequisite dependent condition status ].freeze

  # A Snapshot from the parsed JSON, or Invalid when the envelope itself is
  # wrong (an unknown schema, a missing section): then nothing of it is shown.
  def self.parse(data)
    Parser.new(data).snapshot
  end

  def generated_at_time
    Time.iso8601(generated_at)
  end

  class Parser
    def initialize(data)
      @data = data
      @dropped = Hash.new(0)
      @over_limit = []
    end

    def snapshot
      unless @data.is_a?(Hash) && @data.keys.sort == TOP_KEYS.sort && @data["schema"] == SCHEMA
        raise Invalid, "envelope"
      end

      generated_at = iso(@data["generated_at"]) || raise(Invalid, "generated_at")
      products = section("products", MAX_PRODUCTS) { |product| product(product) }.uniq { |product| product["id"] }
      items = section("items", MAX_ITEMS) { |item| item(item) }
      relations = section("relations", MAX_RELATIONS) { |relation| relation(relation) }

      WorkMap::Snapshot.new(generated_at:, products:, items:, relations:, dropped: @dropped.to_h, over_limit: @over_limit)
    end

    private
      def section(name, limit)
        list = @data[name]
        raise Invalid, name unless list.is_a?(Array)

        @over_limit << name if list.size > limit
        list.first(limit).filter_map do |entry|
          yield(entry).tap { |value| @dropped[name] += 1 if value.nil? }
        end
      end

      def product(value)
        return unless exact?(value, PRODUCT_KEYS, required: %w[ id board_id status ])
        return unless value["id"].is_a?(String) && value["id"].match?(PRODUCT_ID)
        return unless value["board_id"].is_a?(String) && value["board_id"].match?(BOARD_ID)
        return unless value["status"].in?(PRODUCT_STATUSES)
        return unless value["error"].nil? || (value["error"].is_a?(String) && value["error"].match?(ERROR_CODE))
        return unless value["truncated"].nil? || value["truncated"].in?([ true, false ])
        return unless optional_time?(value["read_at"])

        name = text(value["name"], limit: 80)
        { "id" => value["id"], "name" => name.presence || value["id"], "board_id" => value["board_id"],
          "status" => value["status"], "read_at" => iso(value["read_at"]), "error" => value["error"],
          "truncated" => value["truncated"] == true }
      end

      def item(value)
        return unless exact?(value, ITEM_KEYS, required: %w[ product card state ])
        return unless endpoint_fields?(value)
        return unless value["state"].is_a?(String) && value["state"].match?(STATE)

        wait = value["wait"].nil? ? nil : wait(value["wait"])
        return if !value["wait"].nil? && wait.nil?

        milestones = value["milestones"].nil? ? {} : milestones(value["milestones"])
        return if milestones.nil?

        { "product" => value["product"], "card" => value["card"], "state" => value["state"], "wait" => wait, "milestones" => milestones }
      end

      def wait(value)
        return unless exact?(value, WAIT_KEYS, required: %w[ kind ])
        return unless value["kind"].in?(WAIT_KINDS)
        return unless value["human"].nil? || value["human"].in?(HUMAN_CONDITIONS)
        return unless optional_time?(value["since"]) && optional_time?(value["checked_at"])
        return unless optional_text?(value["reason"]) && optional_text?(value["next_step"])

        { "kind" => value["kind"], "reason" => text(value["reason"]), "since" => iso(value["since"]),
          "checked_at" => iso(value["checked_at"]), "human" => value["human"] || "unknown", "next_step" => text(value["next_step"]) }
      end

      def milestones(value)
        return unless exact?(value, MILESTONE_KEYS, required: [])
        return unless MILESTONE_KEYS.all? { |key| optional_time?(value[key]) }

        MILESTONE_KEYS.to_h { |key| [ key, iso(value[key]) ] }
      end

      def relation(value)
        return unless exact?(value, RELATION_KEYS, required: REQUIRED_RELATION_KEYS)
        return unless endpoint?(value["prerequisite"]) && endpoint?(value["dependent"])
        return unless value["condition"].in?(CONDITIONS) && value["status"].in?(RELATION_STATUSES)
        return unless %w[ environment channel ].all? { |key| value[key].nil? || (value[key].is_a?(String) && value[key].match?(SCOPE)) }
        return unless optional_time?(value["since"]) && optional_time?(value["resolved_at"])

        { "prerequisite" => value["prerequisite"].slice(*ENDPOINT_KEYS), "dependent" => value["dependent"].slice(*ENDPOINT_KEYS),
          "condition" => value["condition"], "environment" => value["environment"], "channel" => value["channel"],
          "status" => value["status"], "since" => iso(value["since"]), "resolved_at" => iso(value["resolved_at"]) }
      end

      def endpoint?(value)
        exact?(value, ENDPOINT_KEYS, required: ENDPOINT_KEYS) && endpoint_fields?(value)
      end

      def endpoint_fields?(value)
        value["product"].is_a?(String) && value["product"].match?(PRODUCT_ID) &&
          value["card"].is_a?(Integer) && value["card"].positive? && value["card"] < 10**9
      end

      def exact?(value, allowed, required:)
        value.is_a?(Hash) && (value.keys - allowed).empty? && required.all? { |key| !value[key].nil? }
      end

      def optional_time?(value)
        value.nil? || !time(value).nil?
      end

      def optional_text?(value)
        value.nil? || (value.is_a?(String) && value.length <= TEXT_LIMIT)
      end

      def time(value)
        Time.iso8601(value).utc if value.is_a?(String) && value.length <= 40
      rescue ArgumentError
        nil
      end

      def iso(value)
        time(value)&.iso8601
      end

      # Plain text only: control characters become spaces, so nothing the
      # producer writes can break a line of the panel or smuggle markup.
      def text(value, limit: TEXT_LIMIT)
        value.to_s.gsub(/[[:cntrl:]]+/, " ").squish.first(limit).presence if value.is_a?(String)
      end
  end
end
