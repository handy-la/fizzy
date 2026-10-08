require "test_helper"

class Signups::CompletionsControllerTest < ActionDispatch::IntegrationTest
  test "single tenant completion rejects an authenticated member" do
    sign_in_as identities(:david)

    with_multi_tenant_mode(false) do
      Signup.any_instance.expects(:create_tenant).never
      untenanted do
        assert_no_difference [ "Account.count", "User.count", "Account::JoinCode.count" ] do
          assert_no_enqueued_jobs do
            post signup_completion_path, params: { signup: { full_name: "David" } }, as: :json
          end
        end
        assert_response :unprocessable_entity
      end
    end
  end

  test "multi tenant completion still creates an account" do
    sign_in_as identities(:david)

    untenanted do
      assert_difference "Account.count", 1 do
        post signup_completion_path, params: { signup: { full_name: "David" } }, as: :json
      end
      assert_response :created
    end
  end
end
