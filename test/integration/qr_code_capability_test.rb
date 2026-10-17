require "test_helper"

# A QR code encodes a capability: the auto-login link of a session transfer, or an invite link.
# It is drawn inside the authenticated page that shows it, never fetched from a URL that carries
# the capability, because the request log records every path. See docs/test-audits/handy-1203.md.
class QrCodeCapabilityTest < ActionDispatch::IntegrationTest
  test "the auto-login QR code is embedded in the owner's page, not linked to a public URL" do
    identities(:kevin).transfer_id
    sign_in_as :kevin

    get user_path(users(:kevin))

    assert_response :success
    assert_qr_code_embedded
  end

  test "the invite QR code is embedded in the page, not linked to a public URL" do
    sign_in_as :kevin

    get account_join_code_path

    assert_response :success
    assert_qr_code_embedded
  end

  test "a QR code URL captured from a log no longer resolves" do
    token = identities(:kevin).transfer_id
    url = untenanted { session_transfer_url(token) }
    captured = ActiveSupport::MessageVerifier
      .new(Rails.application.key_generator.generate_key("qr_codes"), url_safe: true)
      .generate(url, purpose: :qr_code)

    get "#{accounts("37s").slug}/qr_codes/#{captured}"

    assert_response :not_found
    assert_not_includes response.body, "<svg"
  end

  private
    def assert_qr_code_embedded
      assert_select "img.qr-code", count: 1 do |(image)|
        assert image["src"].start_with?("data:image/svg+xml;base64,"), "QR code src should be a data URI, was #{image["src"].first(40)}"
        assert_includes Base64.strict_decode64(image["src"].delete_prefix("data:image/svg+xml;base64,")), "<svg"
      end
      assert_no_match %r{/qr_codes/}, response.body
    end
end
