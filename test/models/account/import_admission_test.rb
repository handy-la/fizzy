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
end
