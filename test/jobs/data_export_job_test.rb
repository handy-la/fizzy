require "test_helper"

class DataExportJobTest < ActiveSupport::TestCase
  test "account exports share one execution slot across requesting users" do
    first = Account::Export.create!(account: accounts("37s"), user: users(:jason))
    second = Account::Export.create!(account: accounts("37s"), user: users(:david))
    other = Account::Export.create!(account: accounts(:initech), user: users(:system_initech))

    assert_equal 1, DataExportJob.concurrency_limit
    assert DataExportJob.new(first).concurrency_key.present?
    assert_equal DataExportJob.new(first).concurrency_key, DataExportJob.new(second).concurrency_key
    assert_not_equal DataExportJob.new(first).concurrency_key, DataExportJob.new(other).concurrency_key
  end

  test "personal exports share one execution slot per user independently of account exports" do
    first = User::DataExport.create!(account: accounts("37s"), user: users(:jason))
    second = User::DataExport.create!(account: accounts("37s"), user: users(:jason))
    other = User::DataExport.create!(account: accounts("37s"), user: users(:david))
    account_export = Account::Export.create!(account: accounts("37s"), user: users(:jason))

    assert_equal 1, DataExportJob.concurrency_limit
    assert DataExportJob.new(first).concurrency_key.present?
    assert_equal DataExportJob.new(first).concurrency_key, DataExportJob.new(second).concurrency_key
    assert_not_equal DataExportJob.new(first).concurrency_key, DataExportJob.new(other).concurrency_key
    assert_not_equal DataExportJob.new(first).concurrency_key, DataExportJob.new(account_export).concurrency_key
  end
end
