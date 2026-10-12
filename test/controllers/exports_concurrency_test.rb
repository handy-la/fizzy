require "test_helper"

class ExportsConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Concurrent exports")
    @user = @account.users.create!(name: "Exporter", identity: identities(:david), role: :owner)
    @authorization = "Bearer #{identity_access_tokens(:davids_api_token).token}"
  end

  teardown do
    @account.destroy!
  end

  test "concurrent account requests only create and enqueue ten exports" do
    assert_concurrent_limit("#{@account.slug}/account/exports", Account::Export)
  end

  test "concurrent user requests only create and enqueue ten exports" do
    assert_concurrent_limit("#{@account.slug}/users/#{@user.id}/data_exports", User::DataExport)
  end

  private
    def assert_concurrent_limit(path, export_class)
      start = Queue.new
      delay_count = ->(event) do
        if event.payload[:sql].match?(/SELECT COUNT\(\*\).*exports/i)
          sleep 0.05
        end
      end

      statuses = ActiveSupport::Notifications.subscribed(delay_count, "sql.active_record") do
        threads = 12.times.map do
          Thread.new do
            start.pop
            Rails.application.executor.wrap do
              session = ActionDispatch::Integration::Session.new(Rails.application)
              session.post(path, as: :json, headers: { "Authorization" => @authorization })
              session.response.status
            end
          end
        end
        12.times { start << true }
        threads.map(&:value)
      ensure
        threads&.each(&:join)
      end

      assert_equal 10, statuses.count(201), statuses.tally.inspect
      assert_equal 2, statuses.count(429)
      exports = export_class.where(account: @account)
      assert_equal 10, exports.current.count
      jobs = enqueued_jobs.select { |job| job[:job] == DataExportJob }
      assert_equal exports.map(&:to_global_id).map(&:to_s).sort,
        jobs.map { |job| job[:args].first.fetch("_aj_globalid") }.sort
    end
end
