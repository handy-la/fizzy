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
end
