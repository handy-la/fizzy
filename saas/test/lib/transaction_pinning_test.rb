require "test_helper"
require "yabeda/testing"

# Contract (Handy #965): a request read from the replica continues there only when the replica confirmed
# the session's last transaction. A timeout or an error of WAIT_FOR_EXECUTED_GTID_SET sends the whole
# request to the writer. The fake connection stands in for MySQL's GTID function, which SQLite lacks.
# Authoring answers and RED evidence: docs/test-audits/handy-965.md.
class TransactionPinningTest < ActiveSupport::TestCase
  setup do
    @served_by = []
    @middleware = TransactionPinning::Middleware.new(->(env) {
      @served_by << [ ApplicationRecord.current_role, ApplicationRecord.current_preventing_writes ]
      [ 200, {}, [ "ok" ] ]
    })
  end

  test "a replica that confirmed the session's last transaction serves the request" do
    replica_answers { 0 }

    call_on_replica last_txn: "uuid:1-5"

    assert_equal [ [ :reading, true ] ], @served_by
  end

  test "a request without a pinned transaction stays on the replica without waiting" do
    ApplicationRecord.expects(:connection).never

    call_on_replica last_txn: nil

    assert_equal [ [ :reading, true ] ], @served_by
  end

  test "a replica wait that times out sends the whole request to the writer" do
    replica_answers { 1 }

    _, headers, _ = call_on_replica last_txn: "uuid:1-5"

    assert_equal [ [ :writing, true ] ], @served_by
    assert_equal "true", headers["X-Replica-Stale"]
  end

  test "a replica wait that fails sends the whole request to the writer" do
    replica_answers { raise ActiveRecord::StatementInvalid, "Lost connection to MySQL server" }
    Sentry.expects(:capture_exception)

    call_on_replica last_txn: "uuid:1-5"

    assert_equal [ [ :writing, true ] ], @served_by
  end

  private
    def replica_answers(&answer)
      replica = Object.new
      replica.define_singleton_method(:select_value) do |sql|
        raise "unexpected query: #{sql}" unless sql.include?("WAIT_FOR_EXECUTED_GTID_SET")
        answer.call
      end
      ApplicationRecord.stubs(:connection).returns(replica)
      ApplicationRecord.stubs(:sanitize_sql_array).returns("SELECT WAIT_FOR_EXECUTED_GTID_SET('uuid:1-5', 0.25)")
    end

    def call_on_replica(last_txn:)
      env = Rack::MockRequest.env_for("/")
      env["rack.session"] = { TransactionPinning::Middleware::SESSION_KEY => last_txn }

      ActiveRecord::Base.connected_to(role: :reading, prevent_writes: true) do
        @middleware.call(env)
      end
    end
end
