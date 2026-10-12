require "test_helper"

class Account::ImportAdmissionTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test "simultaneous requests admit only one import for a global identity" do
    sign_in_as identities(:david)
    identity = identities(:david)
    original_account_ids = Account.pluck(:id)
    sessions = 2.times.map do
      open_session.tap { |session| session.cookies["session_token"] = cookies["session_token"] }
    end
    zip = Tempfile.new([ "concurrent-import", ".zip" ])
    zip.binmode
    writer = ZipFile::Writer.new(zip)
    writer.add_file("data/account.json", "{}")
    writer.close
    zip.rewind
    uploads = 2.times.map { Rack::Test::UploadedFile.new(zip.path, "application/zip") }
    ready = Queue.new
    start = Queue.new
    threads = sessions.zip(uploads).map do |session, upload|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          session.post "/account/imports", params: { file: upload }
          session.response.status
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }

    assert_equal [ 302, 429 ], threads.map(&:value).sort
    assert_equal 1, Account::Import.where(identity: identity, status: :pending).count
    assert_equal 1, Account.where.not(id: original_account_ids).count
  ensure
    threads&.each(&:join)
    Account.where.not(id: original_account_ids).find_each(&:destroy!) if original_account_ids
    Account::Import::Admission.where(identity: identity).delete_all if identity
    zip&.close!
  end
end
