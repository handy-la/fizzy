# Evidence received from Dédalo, independent of cards. Writes go through
# Declaration; the board serializes compare-and-swap, including on SQLite.
class TickHealth < ApplicationRecord
  belongs_to :account
  belongs_to :board
  serialize :evidence, coder: JSON

  STATES = %w[ scheduled running waiting_ci waiting_resource deferred lock_busy noop failed no_signal scheduler_missing disabled ].freeze
  RESULTS = %w[ succeeded noop failed cancelled ].freeze

  after_save_commit :notify_board

  def self.stream_name(board)
    "tick-health:#{board.account_id}:#{board.id}"
  end

  def self.snapshot(board, registry: TickHealth::Registry.for(board), now: Time.current)
    rows = where(board: board).index_by(&:stage_id)
    column_ids = board.columns.where(account_id: board.account_id).ids
    {
      schema: 1, product_id: registry&.fetch("id"), board_id: board.id, server_time: now.utc.iso8601(6),
      stages: (registry&.fetch("stages") || []).filter_map do |stage|
        next unless column_ids.include?(stage["column_id"])
        row = rows[stage["id"]]
        row = nil unless row&.product_id == registry["id"]
        evidence = row&.evidence || { "state" => "no_signal" }
        evidence.merge(
          "product_id" => registry["id"], "stage_id" => stage["id"], "column_id" => stage["column_id"], "description" => stage["description"],
          "revision" => row&.revision || 0,
          "freshness" => row && Time.iso8601(evidence.fetch("valid_until")) > now ? "current" : "stale")
      end
    }
  end

  private
    def notify_board
      # Notifications never carry evidence. The channel reauthorizes and reads
      # committed state; unavailable observability must not roll back the tick.
      ActionCable.server.broadcast(self.class.stream_name(board), { changed: true })
    rescue StandardError => error
      Rails.error.report(error, handled: true)
    end
end
