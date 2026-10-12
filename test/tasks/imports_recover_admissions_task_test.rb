require "test_helper"
require "rake"

# Contract: docs/test-audits/handy-953.md.
class ImportsRecoverAdmissionsTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("imports:recover_admissions")
    Rake::Task["imports:recover_admissions"].reenable
    @identity = identities(:david)
  end

  test "recovers each safe slot, keeps the others and exits with failure" do
    stale = Account::Import::Admission.claim(identity: @identity)
    travel Account::Import::Admission::STALE_AFTER + 1.minute
    active = Account::Import::Admission.create!(identity: @identity)

    output, _ = capture_io do
      with_env("EMAIL" => @identity.email_address) do
        assert_raises(SystemExit) { Rake::Task["imports:recover_admissions"].invoke }
      end
    end

    assert stale.reload.finished_at
    assert_nil active.reload.finished_at
    assert_match "Recovered admission #{stale.id}", output
    assert_match "Admission #{active.id} kept", output
  end

  private
    def with_env(values)
      previous = values.keys.index_with { |key| ENV[key] }
      ENV.update(values)
      yield
    ensure
      ENV.update(previous)
    end
end
