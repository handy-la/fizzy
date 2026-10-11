require "test_helper"

class Users::DataExportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :david
    @user = users(:david)
  end

  test "create creates an export record and enqueues job" do
    assert_difference -> { User::DataExport.count }, 1 do
      assert_enqueued_with(job: DataExportJob) do
        post user_data_exports_path(@user)
      end
    end

    assert_redirected_to @user
    assert_equal "Export started. You'll receive an email when it's ready.", flash[:notice]
  end

  test "create associates export with user and account" do
    post user_data_exports_path(@user)

    export = User::DataExport.last
    assert_equal @user, export.user
    assert_equal Current.account, export.account
    assert export.pending?
  end

  test "create rejects request when current export limit is reached" do
    Users::DataExportsController::CURRENT_EXPORT_LIMIT.times do
      @user.data_exports.create!(account: Current.account)
    end

    assert_no_difference -> { User::DataExport.count } do
      post user_data_exports_path(@user)
    end

    assert_response :too_many_requests
  end

  test "create allows request when completed exports are older than one day" do
    Users::DataExportsController::CURRENT_EXPORT_LIMIT.times do
      @user.data_exports.create!(account: Current.account, created_at: 2.days.ago, status: :completed)
    end

    assert_difference -> { User::DataExport.count }, 1 do
      post user_data_exports_path(@user)
    end

    assert_redirected_to @user
  end

  test "old unfinished exports still occupy slots" do
    @user.data_exports.delete_all
    10.times do |index|
      @user.data_exports.create!(account: Current.account, created_at: 2.days.ago, status: index.even? ? :pending : :processing)
    end

    assert_no_difference -> { User::DataExport.count } do
      assert_no_enqueued_jobs only: DataExportJob do
        post user_data_exports_path(@user), as: :json
      end
    end
    assert_response :too_many_requests
  end

  %w[ completed failed ].each do |terminal_status|
    test "#{terminal_status} releases an old unfinished export slot" do
      @user.data_exports.delete_all
      exports = 10.times.map do |index|
        @user.data_exports.create!(account: Current.account, created_at: 2.days.ago, status: index.even? ? :pending : :processing)
      end
      export = exports.last
      if terminal_status == "completed"
        export.build
      else
        ZipFile.stubs(:create_for).raises(IOError.new("ZIP failure"))
        assert_raises(IOError) { export.build }
      end
      assert_equal terminal_status, export.reload.status

      assert_difference -> { User::DataExport.count }, 1 do
        assert_enqueued_with(job: DataExportJob) do
          post user_data_exports_path(@user), as: :json
        end
      end
      assert_response :created
    end

    test "#{terminal_status} exports still consume the daily limit" do
      @user.data_exports.delete_all
      10.times do
        @user.data_exports.create!(account: Current.account, status: terminal_status)
      end
      assert_no_difference -> { @user.data_exports.count } do
        assert_no_enqueued_jobs only: DataExportJob do
          post user_data_exports_path(@user), as: :json
        end
      end
      assert_response :too_many_requests
    end
  end

  test "show displays completed export with download link" do
    export = @user.data_exports.create!(account: Current.account)
    export.build

    get user_data_export_path(@user, export)

    assert_response :success
    assert_select "a#download-link"
    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "show displays a warning if the export is missing" do
    get user_data_export_path(@user, "not-really-an-export")

    assert_response :success
    assert_select "h2", "Download Expired"
  end

  test "create as JSON" do
    assert_difference -> { User::DataExport.count }, 1 do
      assert_enqueued_with(job: DataExportJob) do
        post user_data_exports_path(@user), as: :json
      end
    end

    assert_response :created
    body = @response.parsed_body
    assert body["id"].present?
    assert_equal "pending", body["status"]
    assert_nil body["download_url"]
  end

  test "show as JSON with completed export" do
    export = @user.data_exports.create!(account: Current.account)
    export.build

    get user_data_export_path(@user, export), as: :json
    assert_response :success

    body = @response.parsed_body
    assert_equal export.id, body["id"]
    assert_equal "completed", body["status"]
    assert body["download_url"].present?
  end

  test "show as JSON with pending export" do
    export = @user.data_exports.create!(account: Current.account)

    get user_data_export_path(@user, export), as: :json
    assert_response :success

    body = @response.parsed_body
    assert_equal export.id, body["id"]
    assert_equal "pending", body["status"]
    assert_nil body["download_url"]
  end

  test "show as JSON with failed export" do
    export = @user.data_exports.create!(account: Current.account, status: :failed)

    get user_data_export_path(@user, export), as: :json
    assert_response :success

    body = @response.parsed_body
    assert_equal export.id, body["id"]
    assert_equal "failed", body["status"]
    assert_nil body["download_url"]
  end

  test "show as JSON with missing export" do
    get user_data_export_path(@user, "nonexistent"), as: :json
    assert_response :not_found
  end

  test "create is forbidden for other users" do
    other_user = users(:kevin)

    post user_data_exports_path(other_user)

    assert_response :forbidden
  end

  test "create as JSON is forbidden for other users" do
    other_user = users(:kevin)

    post user_data_exports_path(other_user), as: :json

    assert_response :forbidden
  end

  test "show is forbidden for other users" do
    other_user = users(:kevin)
    export = other_user.data_exports.create!(account: Current.account)
    export.build

    get user_data_export_path(other_user, export)

    assert_response :forbidden
  end

  test "show as JSON is forbidden for other users" do
    other_user = users(:kevin)
    export = other_user.data_exports.create!(account: Current.account)
    export.build

    get user_data_export_path(other_user, export), as: :json

    assert_response :forbidden
  end

  test "create as JSON rejects request when current export limit is reached" do
    Users::DataExportsController::CURRENT_EXPORT_LIMIT.times do
      @user.data_exports.create!(account: Current.account)
    end

    assert_no_difference -> { User::DataExport.count } do
      post user_data_exports_path(@user), as: :json
    end

    assert_response :too_many_requests
  end
end
