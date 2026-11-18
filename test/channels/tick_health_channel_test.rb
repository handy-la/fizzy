require "test_helper"

# Authoring: docs/test-audits/handy-2575.md.
class TickHealthChannelTest < ActionCable::Channel::TestCase
  setup do
    stub_connection current_user: users(:david)
  end

  test "the stream is account and board scoped and recovery reads a snapshot" do
    subscribe board_id: boards(:writebook).id
    assert subscription.confirmed?
    assert_has_stream TickHealth.stream_name(boards(:writebook))
    perform :recover
    assert_equal boards(:writebook).id, transmissions.last["board_id"]
    assert_empty transmissions.last["stages"]
  end

  test "other boards accounts inactive users and cancelled accounts cannot subscribe" do
    subscribe board_id: boards(:private).id
    assert subscription.rejected?
    subscribe board_id: boards(:miltons_wish_list).id
    assert subscription.rejected?
    users(:david).update!(active: false)
    subscribe board_id: boards(:writebook).id
    assert subscription.rejected?
    users(:david).update!(active: true)
    accounts(:'37s').cancel(initiated_by: users(:david))
    subscribe board_id: boards(:writebook).id
    assert subscription.rejected?
  end

  test "revoking board access closes the stream before the next snapshot" do
    subscribe board_id: boards(:writebook).id
    assert subscription.confirmed?
    accesses(:writebook_david).destroy!
    perform :recover
    assert_no_streams
    assert_equal "access_revoked", transmissions.last["error"]
    assert_nil transmissions.last["stages"]
  end
end
