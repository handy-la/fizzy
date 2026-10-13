require "test_helper"

# Handy #968: a slot is exclusive and a release only removes its own row. docs/test-audits/handy-968.md.
class Storage::RepresentationSlotTest < ActiveSupport::TestCase
  setup { @account_id = accounts("37s").id }

  test "a position is held by one slot at a time" do
    held = 2.times.map { acquire }

    assert held.all?
    assert_nil acquire
    assert_equal [ 0, 1 ], held.map(&:position).sort
  end

  test "another account has its own positions" do
    2.times { acquire }

    assert Storage::RepresentationSlot.acquire(accounts(:initech).id, positions: 2, expires_in: 3.minutes)
  end

  test "releasing frees the position" do
    first = acquire
    acquire

    first.release

    assert acquire
  end

  test "an expired slot is taken over, and its late release does not free the new holder" do
    stale = acquire

    travel 4.minutes
    takeover = acquire
    assert_equal stale.position, takeover.position
    assert acquire

    stale.release
    assert_nil acquire, "the late release must not have deleted the new holder's row"
  end

  private
    def acquire
      Storage::RepresentationSlot.acquire(@account_id, positions: 2, expires_in: 3.minutes)
    end
end
