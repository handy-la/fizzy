require "test_helper"
require "open3"

class JavascriptTest < ActiveSupport::TestCase
  test "push subscription browser lifecycle" do
    output, status = Open3.capture2e("node", "--experimental-vm-modules", "--test", "test/javascript/push_subscriptions_test.mjs", chdir: Rails.root)
    assert status.success?, output
  end
end
