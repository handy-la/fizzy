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

  test "a renewed slot is not taken over while its holder still works" do
    held = 2.times.map { acquire }

    travel 2.minutes
    held.each { |slot| slot.renew(expires_in: 3.minutes) }
    travel 2.minutes

    assert_nil acquire, "a slot renewed a minute ago must not have expired"
  end

  test "a held slot is renewed while the block runs, and no more once it returns" do
    slot = acquire
    renewals = count_renewals(slot)

    assert_equal :done, slot.hold(expires_in: 3.minutes, renew_every: 0.01) { sleep 0.2; :done }
    assert_operator renewals.size, :>, 0

    after = renewals.size
    sleep 0.1
    assert_equal after, renewals.size
  end

  test "a held slot stops renewing when the block raises" do
    slot = acquire
    renewals = count_renewals(slot)

    assert_raises(RuntimeError) { slot.hold(expires_in: 3.minutes, renew_every: 0.01) { sleep 0.1; raise "boom" } }

    after = renewals.size
    sleep 0.1
    assert_equal after, renewals.size
  end

  # SaaS configures a replica, and a GET may run on it; connected_to only works on the abstract class.
  test "acquires and releases when a replica is configured" do
    ActiveRecord::Base.stubs(:replica_configured?).returns(true)

    slot = acquire
    assert slot

    slot.release
    assert_not Storage::RepresentationSlot.exists?(slot.id)
  end

  private
    def count_renewals(slot)
      [].tap do |renewals|
        slot.stubs(:renew).with { |expires_in:| renewals << expires_in }
      end
    end

    def acquire
      Storage::RepresentationSlot.acquire(@account_id, positions: 2, expires_in: 3.minutes)
    end
end
