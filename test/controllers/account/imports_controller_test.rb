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
end
