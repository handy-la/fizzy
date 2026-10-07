require "test_helper"

class Account::CancellableTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:"37s")
    @user = users(:david)
  end

  test "cancel" do
    assert_difference -> { Account::Cancellation.count }, 1 do
      assert_enqueued_with(job: ActionMailer::MailDeliveryJob) do
        @account.cancel(initiated_by: @user)
      end
    end

    assert @account.cancelled?
    assert_equal @user, @account.cancellation.initiated_by
  end

  test "cancel does nothing if already cancelled" do
    @account.cancel(initiated_by: @user)

    assert_no_changes -> { @account.cancellation.reload.created_at } do
      @account.cancel(initiated_by: @user)
    end
  end

  test "cancel revokes suggestions only for this account and reactivation does not restore them" do
    requests = %w[ pending running completed ].map.with_index do |status, index|
      Card::SuggestionRequest.create!(card: cards(:logo), user: [ @user, users(:jz), users(:kevin) ][index], kind: "comment",
        token: SecureRandom.hex(16), fingerprint: "context", status: status,
        suggestion: status == "completed" ? "Texto reservado" : nil, description: "Contexto reservado",
        requested_at: Time.current, expires_at: 10.minutes.from_now)
    end
    other = Card::SuggestionRequest.request(cards(:radio), user: users(:mike), kind: "comment")

    @account.cancel(initiated_by: @user)

    requests.each do |request|
      assert_equal "failed", request.reload.status
      assert_equal "access_revoked", request.error_category
      assert_nil request.suggestion
      assert_nil request.description
    end
    assert_equal "pending", other.reload.status
    @account.reactivate
    assert requests.all? { |request| request.reload.error_category == "access_revoked" }
  end

  test "cancel disconnects all account users without disconnecting their other memberships" do
    users(:mike).update!(identity: @user.identity)
    @account.users.each do |user|
      remote = mock("remote connection for #{user.id}")
      ActionCable.server.remote_connections.expects(:where).with(current_user: user).returns(remote)
      remote.expects(:disconnect).with(reconnect: false)
    end

    @account.cancel(initiated_by: @user)

    assert users(:mike).reload.active?
    assert accounts(:initech).active?
  end

  test "rolled back cancellation preserves suggestions and connections" do
    request = Card::SuggestionRequest.request(cards(:logo), user: @user, kind: "comment")
    ActionCable.server.remote_connections.expects(:where).never

    Account.transaction(requires_new: true) do
      @account.cancel(initiated_by: @user)
      raise ActiveRecord::Rollback
    end

    assert @account.reload.active?
    assert_equal "pending", request.reload.status
    assert_nil request.error_category
  end

  test "cancel does nothing when in single-tenant mode" do
    Account.stubs(:accepting_signups?).returns(false)

    assert_no_difference -> { Account::Cancellation.count } do
      @account.cancel(initiated_by: @user)
    end

    assert_not @account.cancelled?
  end

  test "cancelled? returns true when cancellation exists" do
    assert_not @account.cancelled?

    @account.cancel(initiated_by: @user)

    assert @account.cancelled?
  end

  test "reactivate" do
    @account.cancel(initiated_by: @user)

    assert @account.cancelled?

    @account.reactivate
    @account.reload

    assert_not @account.cancelled?
    assert_nil @account.cancellation
  end

  test "reactivate does nothing if not cancelled" do
    assert_not @account.cancelled?

    assert_nothing_raised do
      @account.reactivate
    end

    assert_not @account.cancelled?
  end

  test "active scope excludes cancelled accounts" do
    account2 = accounts(:initech)

    initial_active_count = Account.active.count

    @account.cancel(initiated_by: @user)

    assert_equal initial_active_count - 1, Account.active.count
    assert_not_includes Account.active, @account
    assert_includes Account.active, account2
  end
end
