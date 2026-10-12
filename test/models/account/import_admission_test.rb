require "test_helper"

class Account::ImportAdmissionReservationTest < ActiveSupport::TestCase
  setup do
    @account = accounts("37s")
    @identity = identities(:david)
  end

  test "reservation includes existing uploads and is idempotent while processing" do
    @account.stubs(:storage_limit).returns(100)
    Storage::Entry.record(account: @account, delta: 30, operation: "attach")
    admission = Account::Import::Admission.claim(identity: @identity)
    admission.reserve(account: @account, bytes: 70)
    assert_equal 100, @account.bytes_used_exact
    assert_equal 70, @account.bytes_used
    admission.reserve(account: @account, bytes: 70)
    assert_equal 100, @account.bytes_used_exact
    assert_raises(Account::Import::InsufficientStorageSpaceError) { admission.reserve(account: @account, bytes: 71) }
    assert_equal 70, admission.reload.reserved_bytes
  end

  test "unknown account capacity rejects without reserving" do
    @account.stubs(:storage_limit).returns(nil)
    admission = Account::Import::Admission.claim(identity: @identity)
    assert_raises(Account::Import::InsufficientStorageSpaceError) { admission.reserve(account: @account, bytes: 1) }
    assert_equal 0, admission.reload.reserved_bytes
  end

  test "identity budget applies even if the account has a larger storage exception" do
    @account.stubs(:storage_limit).returns(10.gigabytes)
    admission = Account::Import::Admission.claim(identity: @identity)
    assert_raises(Account::Import::InsufficientStorageSpaceError) do
      admission.reserve(account: @account, bytes: 1.gigabyte + 1)
    end
    assert_equal 0, admission.reload.reserved_bytes
  end

  test "finished attempts keep the rolling rate limit and cleanup cannot erase recent attempts" do
    3.times { Account::Import::Admission.claim(identity: @identity).finish }
    Account::Import.cleanup
    error = assert_raises(Account::Import::Admission::Rejected) { Account::Import::Admission.claim(identity: @identity) }
    assert_equal :too_many_requests, error.status
    travel 25.hours do
      Account::Import.cleanup
      assert Account::Import::Admission.claim(identity: @identity)
    end
  end

  # Contract and RED exception: docs/test-audits/handy-953.md.
  test "a slot left by a stopped request blocks imports until the safe recovery" do
    account = Account.create!(name: "Interrupted Import")
    admission = Account::Import::Admission.claim(identity: @identity)
    admission.reserve(account: account, bytes: 70)
    # The process stops here: no import, no finish.

    assert_rejected_claim
    assert_raises(Account::Import::Admission::NotRecoverable) { admission.recover }
    assert_nil admission.reload.finished_at

    travel Account::Import::Admission::STALE_AFTER + 1.minute do
      admission.recover
      assert admission.reload.finished_at
      assert_equal 0, account.bytes_used_exact
      assert Account::Import::Admission.claim(identity: @identity)
    end
  end

  test "recovery refuses while the reserved account has an active import" do
    account = Account.create!(name: "Interrupted Import")
    admission = Account::Import::Admission.claim(identity: @identity)
    admission.reserve(account: account, bytes: 70)
    account.imports.create!(identity: @identity)

    travel Account::Import::Admission::STALE_AFTER + 1.minute do
      error = assert_raises(Account::Import::Admission::NotRecoverable) { admission.recover }
      assert_match(/active import/, error.message)
      assert_nil admission.reload.finished_at
      assert_equal 70, account.bytes_used_exact
    end
  end

  test "a destroyed account keeps the slot until its objects are deleted" do
    account = Account.create!(name: "Destroyed Import")
    import = account.imports.create!(identity: @identity)
    Current.set(account: account) do
      import.file.attach(io: StringIO.new("zip bytes"), filename: "export.zip", content_type: "application/zip")
    end
    admission = Account::Import::Admission.claim(identity: @identity, import: import)
    admission.reserve(account: account, bytes: 70)
    blob = import.file.blob

    account.destroy!
    assert_rejected_claim

    travel Account::Import::Admission::STALE_AFTER + 1.minute do
      error = assert_raises(Account::Import::Admission::NotRecoverable) { admission.recover }
      assert_match(/storage objects/, error.message)
      assert_equal 70, admission.reload.reserved_bytes

      perform_enqueued_jobs
      assert_not ActiveStorage::Blob.exists?(blob.id)
      admission.recover
      assert admission.reload.finished_at
      assert Account::Import::Admission.claim(identity: @identity)
    end
  end

  test "recovering a failed import deletes its objects before releasing the charge" do
    account = Account.create!(name: "Failed Import")
    import = account.imports.create!(identity: @identity)
    Current.set(account: account) do
      import.file.attach(io: StringIO.new("zip bytes"), filename: "export.zip", content_type: "application/zip")
    end
    admission = Account::Import::Admission.claim(identity: @identity, import: import)
    admission.reserve(account: account, bytes: 70)
    import.update_column(:status, "failed")
    blob = import.file.blob
    blob.service.stubs(:delete).raises(IOError, "storage unavailable")

    assert_raises(IOError) { admission.recover }
    assert ActiveStorage::Blob.exists?(blob.id)
    assert_equal 70, admission.reload.reserved_bytes
    assert_nil admission.finished_at

    blob.service.unstub(:delete)
    admission.recover
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert admission.reload.finished_at
  end

  private
    def assert_rejected_claim
      error = assert_raises(Account::Import::Admission::Rejected) { Account::Import::Admission.claim(identity: @identity) }
      assert_equal :too_many_requests, error.status
    end
end
