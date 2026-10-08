require "test_helper"

class ActiveStorage::DirectUploadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @blob_params = {
      blob: {
        filename: "screenshot.png",
        byte_size: 12345,
        checksum: "GQ5SqLsM7ylnji0Wgd9wNC==",
        content_type: "image/png"
      }
    }
  end

  test "create" do
    sign_in_as :david

    post rails_direct_uploads_path,
      params: @blob_params,
      headers: bearer_token_header(identity_access_tokens(:davids_api_token).token),
      as: :json

    assert_response :success
    assert_includes response.parsed_body.keys, "direct_upload"
  end

  test "create with valid access token" do
    post rails_direct_uploads_path,
      params: @blob_params,
      headers: bearer_token_header(identity_access_tokens(:davids_api_token).token),
      as: :json

    assert_response :success
    assert_includes response.parsed_body.keys, "direct_upload"
  end

  test "create with session token" do
    sign_in_as :david

    post rails_direct_uploads_path,
      params: @blob_params,
      as: :json

    assert_response :success
    assert_includes response.parsed_body.keys, "direct_upload"
  end

  test "create with session token skips forgery protection" do
    sign_in_as :david

    with_forgery_protection do
      post rails_direct_uploads_path,
        params: @blob_params,
        as: :json

      assert_response :success
      assert_includes response.parsed_body.keys, "direct_upload"
    end
  end

  test "create with session token from a cross-site request is forbidden" do
    sign_in_as :david

    with_forgery_protection do
      post rails_direct_uploads_path,
        params: @blob_params,
        headers: { "Sec-Fetch-Site" => "cross-site" },
        as: :json

      assert_response :unprocessable_entity
    end
  end

  test "create with read-only access token" do
    post rails_direct_uploads_path,
      params: @blob_params,
      headers: bearer_token_header(identity_access_tokens(:jasons_api_token).token),
      as: :json

    assert_response :unauthorized
  end

  test "create with invalid access token" do
    post rails_direct_uploads_path,
      params: @blob_params,
      headers: bearer_token_header("invalid_token"),
      as: :json

    assert_response :unauthorized
  end

  test "create unauthenticated" do
    post rails_direct_uploads_path,
      params: @blob_params,
      as: :json

    assert_response :redirect
  end

  test "create in another account is forbidden" do
    sign_in_as :david

    post rails_direct_uploads_path(script_name: "/#{ActiveRecord::FixtureSet.identify("initech")}"),
      params: @blob_params,
      as: :json

    assert_response :forbidden
  end

  test "create with valid access token in another account is forbidden" do
    post rails_direct_uploads_path(script_name: "/#{ActiveRecord::FixtureSet.identify("initech")}"),
      params: @blob_params,
      headers: bearer_token_header(identity_access_tokens(:davids_api_token).token),
      as: :json

    assert_response :forbidden
  end

  test "oversized upload does not create a blob" do
    sign_in_as :david
    @blob_params[:blob][:byte_size] = 100.megabytes + 1

    assert_no_difference "ActiveStorage::Blob.count" do
      post rails_direct_uploads_path, params: @blob_params, as: :json
      assert_response :content_too_large
    end
  end

  test "remaining quota includes unmaterialized attachments" do
    sign_in_as :david
    Storage::Entry.record(account: accounts("37s"), delta: 10.gigabytes - 12344, operation: "attach")

    assert_no_difference "ActiveStorage::Blob.count" do
      post rails_direct_uploads_path, params: @blob_params, as: :json
      assert_response :unprocessable_entity
    end
  end

  test "pending upload immediately consumes account storage" do
    sign_in_as :david
    account = accounts("37s")
    before = account.bytes_used
    post rails_direct_uploads_path, params: @blob_params, as: :json
    assert_response :success

    assert_equal before + 12345, account.reload.bytes_used
    assert_equal 12345, account.bytes_used_exact
  end

  test "identity cannot accumulate more than twenty pending uploads" do
    sign_in_as :david
    20.times do
      post rails_direct_uploads_path, params: @blob_params, as: :json
      assert_response :success
    end

    assert_no_difference "ActiveStorage::Blob.count" do
      post rails_direct_uploads_path, params: @blob_params, as: :json
      assert_response :too_many_requests
    end
  end

  test "zero and fractional sizes do not create blobs" do
    sign_in_as :david
    [ 0, -1, "1.5" ].each do |size|
      @blob_params[:blob][:byte_size] = size
      assert_no_difference "ActiveStorage::Blob.count" do
        post rails_direct_uploads_path, params: @blob_params, as: :json
        assert_response :unprocessable_entity
      end
    end
  end

  test "disk URL enforces the reserved length and expires within one hour" do
    sign_in_as :david
    @blob_params[:blob].merge!(byte_size: 1, checksum: Digest::MD5.base64digest("h"), content_type: "text/plain")
    post rails_direct_uploads_path, params: @blob_params, as: :json
    assert_response :success
    url = response.parsed_body.fetch("direct_upload").fetch("url")

    put url, params: "hello", headers: { "Content-Type" => "text/plain" }
    assert_response :unprocessable_entity
    put url, params: "h", headers: { "Content-Type" => "text/plain" }
    assert_response :no_content

    travel 2.hours do
      put url, params: "h", headers: { "Content-Type" => "text/plain" }
      assert_response :not_found
    end
  end

  private
    def bearer_token_header(token)
      { "Authorization" => "Bearer #{token}" }
    end

    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
end
