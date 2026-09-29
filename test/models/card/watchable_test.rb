require "test_helper"

class Card::WatchableTest < ActiveSupport::TestCase
  setup do
    Watch.destroy_all
    Access.all.update!(involvement: :access_only)
  end

  test "watched_by?" do
    assert_not cards(:logo).watched_by?(users(:kevin))

    cards(:logo).watch_by users(:kevin)
    assert cards(:logo).watched_by?(users(:kevin))

    cards(:logo).unwatch_by users(:kevin)
    assert_not cards(:logo).watched_by?(users(:kevin))
  end

  # Handy: this Fizzy is run for agents, so creating a card never subscribes
  # its creator. Watching is opt-in through the card's watch button.
  test "creating a card does not make its creator watch it" do
    card = boards(:writebook).cards.create!(creator: users(:kevin))

    assert_not card.watched_by?(users(:kevin))
  end

  test "watchers" do
    boards(:writebook).access_for(users(:kevin)).watching!
    boards(:writebook).access_for(users(:jz)).watching!

    cards(:logo).watch_by users(:kevin)
    cards(:logo).unwatch_by users(:jz)
    cards(:logo).watch_by users(:david)

    assert_equal [ users(:kevin), users(:david) ].sort, cards(:logo).watchers.sort

    # Only active users
    users(:david).system!
    assert_equal [ users(:kevin) ].sort, cards(:logo).watchers.reload.sort
  end
end
