# Handy: the numbers behind the leaderboard page, so whoever runs the board
# sees how much has shipped. A card counts as deployed or published the first
# time it entered a stage of that name, on any board the user can see; cards
# sitting in such a stage with no recorded entry count from their last activity.
class Leaderboard
  STAGES = { deployed: "DEPLOYED", published: "PUBLISHED" }.freeze
  MILESTONES = [ 1, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000 ].freeze
  DAYS_CHARTED = 14
  TOP_PEOPLE = 5

  Entry = Struct.new(:card_id, :board_id, :creator_id, :at, keyword_init: true)

  attr_reader :user, :now

  def initialize(user, now: Time.current)
    @user = user
    @now = now
  end

  def deployed
    stage_entries.fetch(:deployed)
  end

  def published
    stage_entries.fetch(:published)
  end

  # Every card that reached DEPLOYED or PUBLISHED, once, at its first arrival.
  def shipped
    @shipped ||= (deployed + published).group_by(&:card_id).values.map { |entries| entries.min_by(&:at) }
  end

  def done
    @done ||= Card.published.closed.where(board_id: board_ids)
      .pluck(:id, :board_id, :creator_id, "closures.created_at")
      .map { |card_id, board_id, creator_id, at| Entry.new(card_id:, board_id:, creator_id:, at:) }
  end

  def shipped_today
    shipped.count { |entry| entry.at >= today.beginning_of_day }
  end

  def shipped_this_week
    shipped.count { |entry| entry.at >= today.beginning_of_week }
  end

  def done_today
    done.count { |entry| entry.at >= today.beginning_of_day }
  end

  # Consecutive days, ending today (or yesterday, while today is still young),
  # with at least one card shipped or done.
  def streak
    active_days = (shipped + done).map { |entry| entry.at.in_time_zone.to_date }.to_set
    day = active_days.include?(today) ? today : today.yesterday

    0.step.find { |count| !active_days.include?(day - count) }
  end

  def best_day
    shipped.group_by { |entry| entry.at.in_time_zone.to_date }.transform_values(&:size).max_by { |day, count| [ count, day ] }
  end

  def daily_shipped
    counts = shipped.group_by { |entry| entry.at.in_time_zone.to_date }.transform_values(&:size)
    (today - (DAYS_CHARTED - 1)..today).map { |day| [ day, counts.fetch(day, 0) ] }
  end

  def next_milestone
    MILESTONES.find { |milestone| milestone > shipped.size }
  end

  def previous_milestone
    MILESTONES.reverse.find { |milestone| milestone <= shipped.size } || 0
  end

  def boards_by_shipped
    counts = shipped.group_by(&:board_id).transform_values(&:size)
    boards.map { |board| [ board, counts.fetch(board.id, 0) ] }.sort_by { |board, count| [ -count, board.name.downcase ] }
  end

  def top_people
    counts = shipped.group_by(&:creator_id).transform_values(&:size)
    people = User.where(id: counts.keys).index_by(&:id)
    counts.filter_map { |id, count| [ people[id], count ] if people[id] }
      .sort_by { |person, count| [ -count, person.name.downcase ] }.first(TOP_PEOPLE)
  end

  private
    def today
      now.in_time_zone.to_date
    end

    def boards
      @boards ||= user.boards.alphabetically.to_a
    end

    def board_ids
      boards.map(&:id)
    end

    def stage_entries
      @stage_entries ||= STAGES.to_h do |stage, name|
        [ stage, (entries_from_events(name) + entries_from_current_columns(name)).group_by(&:card_id).values.map { |entries| entries.min_by(&:at) } ]
      end
    end

    def entries_from_events(stage_name)
      triage_events.filter_map do |card_id, board_id, particulars, at|
        if particulars.to_h.dig("particulars", "column").to_s.strip.casecmp?(stage_name)
          Entry.new(card_id:, board_id:, creator_id: card_creators[card_id], at:)
        end
      end.select(&:creator_id)
    end

    def entries_from_current_columns(stage_name)
      Card.published.joins(:column).where(board_id: board_ids)
        .where("UPPER(TRIM(columns.name)) = ?", stage_name)
        .pluck(:id, :board_id, :creator_id, :last_active_at)
        .map { |card_id, board_id, creator_id, at| Entry.new(card_id:, board_id:, creator_id:, at:) }
    end

    def triage_events
      @triage_events ||= Event.where(board_id: board_ids, action: "card_triaged", eventable_type: "Card")
        .pluck(:eventable_id, :board_id, :particulars, :created_at)
    end

    # Only published cards that still exist count; this also drops drafts.
    def card_creators
      @card_creators ||= Card.published.where(id: triage_events.map(&:first).uniq).pluck(:id, :creator_id).to_h
    end
end
