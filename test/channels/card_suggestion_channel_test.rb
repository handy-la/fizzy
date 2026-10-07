require "test_helper"

class CardSuggestionChannelTest < ActionCable::Channel::TestCase
  setup do
    @request = Card::SuggestionRequest.request(cards(:logo), user: users(:kevin), kind: "comment")
    stub_connection current_user: users(:kevin)
  end

  test "subscription is private to the requesting user and token" do
    subscribe token: @request.token, revision: 4
    assert subscription.confirmed?
    assert_has_stream @request.stream_name
    perform :recover
    assert_equal "pending", transmissions.last["status"]
    assert_equal @request.token, transmissions.last["request_id"]
    assert_equal 4, transmissions.last["revision"]
  end

  test "another user and another account cannot subscribe even with the token" do
    [ users(:david), users(:mike) ].each do |user|
      stub_connection current_user: user
      subscribe token: @request.token, revision: 1
      assert subscription.rejected?
    end
  end

  test "recover rechecks current access and never sends revoked text" do
    private_card = with_current_user(:kevin) { boards(:private).cards.create!(title: "Privado", status: :published) }
    request = Card::SuggestionRequest.request(private_card, user: users(:kevin), kind: "comment")
    request.update!(status: "completed", suggestion: "Texto privado")
    subscribe token: request.token, revision: 2
    assert subscription.confirmed?
    perform :recover
    assert_equal "Texto privado", transmissions.last["suggestion"]
    accesses(:private_kevin).destroy!
    perform :recover
    assert_equal "access_revoked", transmissions.last["error_category"]
    assert_nil transmissions.last["suggestion"]
    assert_no_streams
  end

  test "superseded token cannot recover the newer request" do
    subscribe token: @request.token, revision: 3
    @request.update!(token: SecureRandom.hex(16), suggestion: "Nueva respuesta")
    perform :recover
    assert_nil transmissions.last["suggestion"]
    assert_equal "failed", transmissions.last["status"]
    assert_no_streams
  end

  test "a cancelled account cannot subscribe with a valid token" do
    accounts(:'37s').cancel(initiated_by: users(:kevin))
    assert accounts(:'37s').cancelled?

    subscribe token: @request.token, revision: 5
    assert subscription.rejected?
    assert_empty subscription.stream_names
  end

  test "recover after cancellation never sends completed text" do
    @request.update!(status: "completed", suggestion: "Texto reservado")
    subscribe token: @request.token, revision: 6
    perform :recover
    assert_equal "Texto reservado", transmissions.last["suggestion"]

    accounts(:'37s').cancel(initiated_by: users(:kevin))
    perform :recover

    assert_equal "access_revoked", transmissions.last["error_category"]
    assert_nil transmissions.last["suggestion"]
    assert_no_streams
  end

  test "recover rechecks account activity immediately before transmission" do
    @request.update!(status: "completed", suggestion: "Texto reservado")
    subscribe token: @request.token, revision: 7
    Card::SuggestionRequest.any_instance.expects(:state).with {
      accounts(:'37s').cancel(initiated_by: users(:kevin))
      true
    }.returns({ status: "completed", suggestion: "Texto reservado" })

    perform :recover

    assert_equal "access_revoked", transmissions.last["error_category"]
    assert_nil transmissions.last["suggestion"]
    assert_no_streams
  end
end
