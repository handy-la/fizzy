require "test_helper"

class Account::ImportsControllerTest < ActionDispatch::IntegrationTest
  test "single tenant import rejects an authenticated member before storing the file or scheduling work" do
    sign_in_as identities(:david)

    with_multi_tenant_mode(false) do
      Signup.any_instance.expects(:create_tenant).never
      untenanted do
        assert_no_difference [ "Account.count", "User.count", "Account::Import.count", "ActiveStorage::Blob.count" ] do
          assert_no_enqueued_jobs do
            post account_imports_path, params: { file: fixture_file_upload("avatar.png", "image/png") }
          end
        end
        assert_response :unprocessable_entity
      end
    end
  end

  test "multi tenant import creates an account and schedules the import" do
    sign_in_as identities(:david)
    export = Account::Export.create!(account: accounts("37s"), user: users(:david))
    export.build

    untenanted do
      export.file.open do |file|
        assert_difference [ "Account.count", "Account::Import.count" ], 1 do
          assert_enqueued_with(job: Account::DataImportJob) do
            post account_imports_path, params: { file: Rack::Test::UploadedFile.new(file.path, "application/zip") }
          end
        end
      end

      import = Account::Import.last
      assert_equal identities(:david), import.identity
      assert_predicate import.file, :attached?
      assert_redirected_to account_import_path(import, script_name: import.account.slug)
    end
  end
  [ :pending, :processing ].each do |status|
    test "rejects another import for the same identity while #{status}" do
      sign_in_as identities(:david)
      Account::Import.create!(account: accounts(:initech), identity: identities(:david), status: status)

      untenanted do
        assert_no_difference [ "Account.count", "User.count", "Account::Import.count", "ActiveStorage::Blob.count" ] do
          assert_no_enqueued_jobs do
            post account_imports_path, params: { file: fixture_file_upload("avatar.png", "application/zip") }
          end
        end
        assert_response :too_many_requests
      end
    end
  end

  [ :completed, :failed ].each do |status|
    test "allows a new import after #{status}" do
      sign_in_as identities(:david)
      Account::Import.create!(account: accounts(:initech), identity: identities(:david), status: status)

      tempfile = admission_zip
      untenanted do
        assert_difference "Account::Import.count", 1 do
          assert_enqueued_with(job: Account::DataImportJob) do
            post account_imports_path, params: { file: Rack::Test::UploadedFile.new(tempfile.path, "application/zip") }
          end
        end
        assert_response :redirect
      end
    ensure
      tempfile&.close!
    end
  end

  test "another identity with an active import does not consume the callers slot" do
    sign_in_as identities(:david)
    Account::Import.create!(account: accounts(:initech), identity: identities(:jason), status: :processing)

    tempfile = admission_zip
    untenanted do
      assert_difference "Account::Import.count", 1 do
        assert_enqueued_with(job: Account::DataImportJob) do
          post account_imports_path, params: { file: Rack::Test::UploadedFile.new(tempfile.path, "application/zip") }
        end
      end
      assert_response :redirect
    end
  ensure
    tempfile&.close!
  end

  test "compressed upload is bounded before attachment or enqueue" do
    sign_in_as identities(:david)
    tempfile = Tempfile.new([ "large-import", ".zip" ])
    tempfile.truncate(100.megabytes + 1)

    assert_rejected_import(tempfile.path, :content_too_large)
  ensure
    tempfile&.close!
  end

  [ :disk, :s3 ].each do |backend|
    test "#{backend} rejects expanded bytes exceeding the account quota before storing or enqueueing" do
      sign_in_as identities(:david)
      Account.any_instance.stubs(:storage_limit).returns(1.gigabyte).then.returns(1.gigabyte).then.returns(100)
      tempfile = admission_zip { |writer| writer.add_file("storage/object", "x" * 1024) }
      if backend == :s3
        require "active_storage/service/s3_service"
        service = ActiveStorage::Service::S3Service.new(bucket: "import-test", region: "us-east-1",
          access_key_id: "test", secret_access_key: "test")
        service.expects(:upload).never
        ActiveStorage::Blob.stubs(:service).returns(service)
      end

      assert_rejected_import(tempfile.path, :unprocessable_entity)
    ensure
      tempfile&.close!
    end
  end

  test "record budget rejects many small records before inserting any rows" do
    sign_in_as identities(:david)
    tempfile = admission_zip do |writer|
      10_001.times { |index| writer.add_file("data/tags/#{index}.json", "{}") }
    end
    assert_rejected_import(tempfile.path, :unprocessable_entity)
  ensure
    tempfile&.close!
  end

  test "invalid ZIP attempts are rate limited across newly created accounts" do
    sign_in_as identities(:david)
    tempfile = Tempfile.new([ "invalid-import", ".zip" ])
    tempfile.write("not a ZIP")
    tempfile.flush
    3.times { assert_rejected_import(tempfile.path, :unprocessable_entity) }
    assert_rejected_import(tempfile.path, :too_many_requests)
  ensure
    tempfile&.close!
  end

  test "one identity cannot enqueue a second import in another account" do
    sign_in_as identities(:david)
    tempfile = admission_zip
    untenanted do
      post account_imports_path, params: { file: Rack::Test::UploadedFile.new(tempfile.path, "application/zip") }
      assert_response :redirect
    end
    assert_rejected_import(tempfile.path, :too_many_requests)
  ensure
    tempfile&.close!
  end

  test "unknown disk capacity fails before attachment and enqueue" do
    sign_in_as identities(:david)
    Account::Import.stubs(:available_storage_space).returns(nil)
    tempfile = admission_zip
    assert_rejected_import(tempfile.path, :unprocessable_entity)
  ensure
    tempfile&.close!
  end

  private
    def assert_rejected_import(path, status)
      untenanted do
        assert_no_difference [ "Account.count", "Account::Import.count", "ActiveStorage::Blob.count", "Tag.count" ] do
          assert_no_enqueued_jobs only: Account::DataImportJob do
            post account_imports_path, params: { file: Rack::Test::UploadedFile.new(path, "application/zip") }
          end
        end
        assert_response status
      end
    end

    def admission_zip
      tempfile = Tempfile.new([ "admission-import", ".zip" ])
      tempfile.binmode
      writer = ZipFile::Writer.new(tempfile)
      writer.add_file("data/account.json", { name: "Import", join_code: { code: "test", usage_count: 0, usage_limit: nil } }.to_json)
      yield writer if block_given?
      writer.close
      tempfile.rewind
      tempfile
    end
end
