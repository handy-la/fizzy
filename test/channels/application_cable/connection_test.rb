require "test_helper"

module ApplicationCable
  class ConnectionTest < ActionCable::Connection::TestCase
    setup do
      # Use non-37s account to assess that Current.account is set correctly
      @account = accounts(:initech)
      @session = sessions(:mike)
    end

    test "connects with valid session and account info" do
      cookies.signed[:session_token] = @session.signed_id

      connect "/cable", env: { "fizzy.external_account_id" => @account.external_account_id }

      assert_equal users(:mike), connection.current_user
      assert_equal @account, Current.account
    end

    test "rejects with invalid session token" do
      cookies.signed[:session_token] = "invalid-session-id"

      assert_reject_connection do
        connect "/cable", env: { "fizzy.external_account_id" => @account.external_account_id }
      end
    end

    test "rejects when account does not exist" do
      cookies.signed[:session_token] = @session.signed_id

      assert_reject_connection do
        connect "/cable", env: { "fizzy.external_account_id" => -1 }
      end
    end

    test "rejects a cancelled account on connect and reconnect" do
      cookies.signed[:session_token] = @session.signed_id
      @account.cancel(initiated_by: users(:mike))
      assert @account.cancelled?

      2.times do
        assert_reject_connection do
          connect "/cable", env: { "fizzy.external_account_id" => @account.external_account_id }
        end
      end
    end

    test "rejects an importing account" do
      cookies.signed[:session_token] = @session.signed_id
      @account.imports.create!(identity: identities(:mike), status: :pending)

      assert_reject_connection do
        connect "/cable", env: { "fizzy.external_account_id" => @account.external_account_id }
      end
    end
  end
end
