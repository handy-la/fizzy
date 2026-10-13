module TransactionPinning
  class Middleware
    SESSION_KEY = :last_txn
    DEFAULT_MAX_WAIT = 0.25

    def initialize(app)
      @app = app
      @timeout = Rails.application.config.x.transaction_pinning&.timeout&.to_f || DEFAULT_MAX_WAIT
    end

    def call(env)
      request = ActionDispatch::Request.new(env)
      replica_metrics = {}

      status, headers, body =
        if ApplicationRecord.current_role == :reading && !replica_caught_up?(request, replica_metrics)
          # Never continue on a replica whose consistency was not confirmed: serve the whole request from the writer.
          ActiveRecord::Base.connected_to(role: :writing, prevent_writes: ActiveRecord::Base.current_preventing_writes) do
            @app.call(env)
          end
        else
          @app.call(env)
        end
      headers.merge!(replica_metrics.transform_values(&:to_s))

      if ApplicationRecord.current_role == :writing
        capture_transaction_id(request)
      end

      [ status, headers, body ]
    end

    private
      def replica_caught_up?(request, replica_metrics)
        if last_txn = request.session[SESSION_KEY].presence
          has_transaction = tracking_replica_wait_time(replica_metrics) do
            replica_has_transaction(last_txn)
          end

          unless has_transaction
            Yabeda.fizzy.replica_stale.increment
            replica_metrics["X-Replica-Stale"] = true
          end

          has_transaction
        else
          true
        end
      end

      def capture_transaction_id(request)
        request.session[SESSION_KEY] = ApplicationRecord.connection.show_variable("global.gtid_executed")
      end

      def replica_has_transaction(txn)
        sql = ApplicationRecord.sanitize_sql_array([ "SELECT WAIT_FOR_EXECUTED_GTID_SET(?, ?)", txn, @timeout ])
        ApplicationRecord.connection.select_value(sql) == 0
      rescue => e
        Sentry.capture_exception(e, extra: { gtid: txn })
        false # Unknown is not caught up: the request falls back to the writer
      end

      def tracking_replica_wait_time(replica_metrics)
        started_at = Time.current

        Yabeda.fizzy.replica_wait.measure do
          yield
        end.tap do
          replica_metrics["X-Replica-Wait"] = Time.current - started_at
        end
      end
  end
end
