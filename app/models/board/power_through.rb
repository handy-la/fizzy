# Handy #2304: one board's cards that wait for a person, one after another.
#
# A board is a product here: the queue never mixes boards. It holds only the
# cards of the chosen stages that Card::PendingRequest calls pending or in need
# of review, oldest request first, then by number, so the order is stable while
# a person works through it. Skipping or viewing a card writes nothing.
class Board::PowerThrough
  MAYBE = "maybe"
  MAX_CARDS = 200

  Stage = Data.define(:id, :name, :color)
  Entry = Data.define(:card, :request)

  attr_reader :board, :user

  def initialize(board:, user:, stage_ids: nil)
    @board = board
    @user = user
    @requested_stage_ids = Array(stage_ids).flat_map { |id| id.to_s.split(",") }.map(&:strip).compact_blank
  end

  def stages
    @stages ||= [ Stage.new(id: MAYBE, name: "Maybe?", color: "var(--color-card-default)") ] +
      board.columns.sorted.map { |column| Stage.new(id: column.id, name: column.name, color: column.color) }
  end

  def selected_stage_ids
    @selected_stage_ids ||= begin
      known = @requested_stage_ids & stages.map(&:id)
      known.any? ? known : default_stage_ids
    end
  end

  def default_stage_ids
    approval = board.columns.sorted.select(&:awaiting_approval?).map(&:id)
    approval.any? ? approval : stages.map(&:id)
  end

  def selected?(stage)
    selected_stage_ids.include?(stage.id)
  end

  def stage_for(card)
    stages.find { |stage| stage.id == (card.column_id || MAYBE) }
  end

  def entries
    @entries ||= candidate_cards.filter_map do |card|
      request = Card::PendingRequest.for(card, comments: card.comments)
      Entry.new(card:, request:) if request.actionable?
    end.sort_by { |entry| [ entry.request.since, entry.card.number ] }
  end

  def truncated?
    candidate_cards.size >= MAX_CARDS
  end

  def entry_for(number)
    entries.find { |entry| entry.card.number == number.to_i }
  end

  def index_of(entry)
    entries.index(entry)
  end

  private
    def candidate_cards
      @candidate_cards ||= user.accessible_cards.active.where(board:).where(column_id: column_ids)
        .includes(:column, :closure, :not_now, :automatic_waits, comments: [ :creator, :rich_text_body ])
        .order(:number).limit(MAX_CARDS).to_a
    end

    def column_ids
      selected_stage_ids.map { |id| id == MAYBE ? nil : id }
    end
end
