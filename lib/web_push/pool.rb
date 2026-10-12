# This is in lib so we can use it in a thread pool without the Rails executor
class WebPush::Pool
  MAX_THREADS = 50
  MAX_PER_ACCOUNT = 100
  MAX_ACTIVE_PER_ACCOUNT = 5
  MAX_PENDING = 10000

  attr_reader :delivery_pool, :invalidation_pool, :connection, :invalid_subscription_handler

  def initialize(invalid_subscription_handler:)
    @delivery_pool = Concurrent::ThreadPoolExecutor.new(max_threads: MAX_THREADS, max_queue: MAX_THREADS, fallback_policy: :abort)
    @invalidation_pool = Concurrent::FixedThreadPool.new(1)
    @connection = Net::HTTP::Persistent.new(name: "web_push", pool_size: 150)
    @invalid_subscription_handler = invalid_subscription_handler
    @mutex = Mutex.new
    @accounts = {}
    @turns = []
    @pending = @active = 0
    @stopping = false
  end

  def queue(payload, subscriptions)
    subscriptions.each do |subscription|
      deliver_later(payload, subscription)
    end
  end

  def shutdown
    @mutex.synchronize { @stopping = true }
    shutdown_pool(delivery_pool)
    shutdown_pool(invalidation_pool)
    connection.shutdown
  end

  private
    def deliver_later(payload, subscription)
      account_id = subscription.account_id
      if reserve(account_id)
        begin
          # AR and DNS run only after admission and outside worker threads.
          notification = subscription.notification(**payload)
        rescue Exception
          @mutex.synchronize { release(account_id) }
          raise
        end

        @mutex.synchronize do
          @accounts.fetch(account_id)[:queue] << [ notification, subscription.id ]
          dispatch
        end
      end
    end

    def reserve(account_id)
      @mutex.synchronize do
        reason = if @stopping
          "shutdown"
        elsif @accounts.dig(account_id, :total).to_i >= MAX_PER_ACCOUNT
          "account_budget"
        elsif @pending >= MAX_PENDING
          "global_budget"
        end

        if reason
          shed(account_id, reason)
          false
        else
          unless @accounts.key?(account_id)
            @accounts[account_id] = { queue: [], total: 0, active: 0 }
            @turns << account_id
          end
          @accounts[account_id][:total] += 1
          @pending += 1
          true
        end
      end
    end

    # Called under the mutex. Rotate accounts after every dispatch; a slow
    # account can hold at most five workers, leaving capacity for other accounts.
    def dispatch
      while @active < MAX_THREADS
        account_id = next_account
        break unless account_id

        account = @accounts.fetch(account_id)
        notification, id = account[:queue].shift
        account[:active] += 1
        @active += 1
        begin
          post_delivery(account_id, notification, id)
        rescue Concurrent::RejectedExecutionError
          finish(account_id)
          shed(account_id, "executor_rejected")
        end
      end
    end

    def post_delivery(account_id, notification, id)
      delivery_pool.post { perform_delivery(account_id, notification, id) }
    end

    def next_account
      @turns.size.times do
        account_id = @turns.shift
        @turns << account_id
        account = @accounts.fetch(account_id)
        return account_id if account[:queue].any? && account[:active] < MAX_ACTIVE_PER_ACCOUNT
      end
      nil
    end

    def perform_delivery(account_id, notification, id)
      deliver(notification, id)
    rescue Exception => e
      Rails.logger.error "Error in WebPush::Pool.deliver: #{e.class}"
    ensure
      @mutex.synchronize do
        finish(account_id)
        dispatch
      end
    end

    def finish(account_id)
      @accounts.fetch(account_id)[:active] -= 1
      @active -= 1
      release(account_id)
    end

    def release(account_id)
      account = @accounts.fetch(account_id)
      account[:total] -= 1
      @pending -= 1
      if account[:total].zero?
        @accounts.delete(account_id)
        @turns.delete(account_id)
      end
    end

    # Push is best effort: discard the newest delivery, keep already admitted
    # work, and expose the account and cause without message content or keys.
    def shed(account_id, reason)
      Rails.logger.warn "WebPush::Pool discarded account=#{account_id} reason=#{reason}"
    end

    def deliver(notification, id)
      notification.deliver(connection: connection)
    rescue WebPush::ExpiredSubscription, OpenSSL::OpenSSLError
      invalidate_subscription_later(id) if invalid_subscription_handler
    end

    def invalidate_subscription_later(id)
      invalidation_pool.post do
        invalid_subscription_handler.call(id)
      rescue Exception => e
        Rails.logger.error "Error in WebPush::Pool.invalid_subscription_handler: #{e.class}"
      end
    end

    def shutdown_pool(pool)
      pool.shutdown
      pool.kill unless pool.wait_for_termination(1)
    end
end
