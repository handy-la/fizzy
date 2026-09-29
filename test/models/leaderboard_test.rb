require "test_helper"

class LeaderboardTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:kevin)
    Event.where(action: "card_triaged").delete_all

    @deployed = columns(:writebook_on_hold).tap { it.update!(name: "DEPLOYED") }
    @published = columns(:writebook_review).tap { it.update!(name: "Published") }
  end

  test "a card counts as shipped once, at its first arrival in DEPLOYED or PUBLISHED" do
    travel_to 2.days.ago do
      cards(:logo).triage_into(@deployed)
    end
    cards(:logo).triage_into(@published)
    cards(:logo).triage_into(@deployed)
    cards(:layout).triage_into(@published)

    leaderboard = Leaderboard.new(users(:kevin))

    assert_equal [ cards(:logo).id ], leaderboard.deployed.map(&:card_id)
    assert_equal [ cards(:layout), cards(:logo) ].map(&:id).sort, leaderboard.published.map(&:card_id).sort
    assert_equal 2, leaderboard.shipped.size
    assert_equal 1, leaderboard.shipped_today
    assert_equal 2.days.ago.to_date, leaderboard.shipped.find { it.card_id == cards(:logo).id }.at.to_date
  end

  test "a card sitting in a shipped stage counts even without a recorded arrival" do
    cards(:text).update_columns(column_id: @deployed.id)

    assert_includes Leaderboard.new(users(:kevin)).deployed.map(&:card_id), cards(:text).id
  end

  test "only boards the user can access count" do
    cards(:logo).triage_into(@deployed)

    assert_equal 1, Leaderboard.new(users(:kevin)).shipped.size
    assert_empty Leaderboard.new(users(:mike)).shipped
  end

  test "done counts closed cards" do
    assert_equal Card.published.closed.where(board: users(:kevin).boards).count, Leaderboard.new(users(:kevin)).done.size
  end

  test "the streak counts consecutive days with something shipped or done, up to today or yesterday" do
    Closure.delete_all
    [ 3, 2, 1 ].each do |days|
      travel_to days.days.ago do
        boards(:writebook).cards.create!(title: "Shipped #{days} days ago", status: :published).triage_into(@deployed)
      end
    end

    assert_equal 3, Leaderboard.new(users(:kevin)).streak
    assert_equal 0, Leaderboard.new(users(:kevin), now: 2.days.from_now).streak
  end

  test "milestones, best day, daily chart, boards and people" do
    cards(:logo).triage_into(@deployed)
    cards(:layout).triage_into(@published)

    leaderboard = Leaderboard.new(users(:kevin))

    assert_equal 5, leaderboard.next_milestone
    assert_equal 1, leaderboard.previous_milestone
    assert_equal [ Date.current, 2 ], leaderboard.best_day
    assert_equal Leaderboard::DAYS_CHARTED, leaderboard.daily_shipped.size
    assert_equal [ Date.current, 2 ], leaderboard.daily_shipped.last
    assert_equal [ boards(:writebook), 2 ], leaderboard.boards_by_shipped.first
    assert_equal [ [ users(:david), 2 ] ], leaderboard.top_people
  end
end
