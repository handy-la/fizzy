class Webhook::Delivery < ApplicationRecord
  include Rails.application.routes.url_helpers

  class ResponseTooLarge < StandardError; end

  STALE_TRESHOLD = 7.days
  USER_AGENT = "fizzy/1.0.0 Webhook"
  ENDPOINT_TIMEOUT = 7.seconds
  MAX_RESPONSE_SIZE = 100.kilobytes
  STALLED_AFTER = 5.minutes
  RETRY_WINDOW = 24.hours
  RETRY_ERRORS = %w[ dns_lookup_failed connection_timeout destination_unreachable failed_tls ].freeze

  belongs_to :account, default: -> { webhook.account }
  belongs_to :webhook
  belongs_to :event

  store :request, coder: JSON
  store :response, coder: JSON

  enum :state, %w[ pending in_progress completed errored ].index_by(&:itself), default: :pending

  scope :ordered, -> { order created_at: :desc, id: :desc }
  scope :stale, -> { where(created_at: ...STALE_TRESHOLD.ago) }

  after_create_commit :deliver_later

  def self.cleanup(batch_size: 500, pause: 0.1)
    sleep pause until stale.limit(batch_size).delete_all.zero?
  end

  def self.recover_stalled
    in_progress.where(updated_at: ..STALLED_AFTER.ago).find_each(&:recover)
  end

  def recover
    if self.class.where(id: id, state: :in_progress, updated_at: ..STALLED_AFTER.ago)
        .update_all(state: :pending, updated_at: Time.current) == 1
      reload
      Current.with_account(account) { deliver_later }
    end
  end

  def deliver_later
    Webhook::DeliveryJob.set(wait_until: next_attempt_at || Time.current).perform_later(self)
  end

  def deliver
    reload
    recover if in_progress?
    return unless pending?

    if next_attempt_at && next_attempt_at.future?
      deliver_later
    elsif earlier_delivery_pending?
      self.request[:next_attempt_at] = 1.minute.from_now.iso8601(6)
      save!
      deliver_later
    elsif self.class.where(id: id, state: :pending).update_all(state: :in_progress, updated_at: Time.current) == 1
      begin
        reload
        self.request[:first_attempt_at] ||= Time.current.iso8601(6)
        self.request[:attempts] = request[:attempts].to_i + 1
        self.request[:payload] ||= payload
        self.request[:headers] ||= headers
        save!
        # A DNS failure must be resolved again on the next attempt.
        remove_instance_variable(:@resolved_ip) if defined?(@resolved_ip)
        self.response = perform_request

        if retryable_response? && Time.current < retry_deadline
          self.state = :pending
          delay = [ 1.minute * 2**[ request[:attempts] - 1, 5 ].min, 30.minutes ].min
          self.request[:next_attempt_at] = [ Time.current + delay, retry_deadline ].min.iso8601(6)
        else
          self.state = :completed
          self.request.delete(:next_attempt_at)
        end
        save!

        if pending?
          deliver_later
        else
          webhook.delinquency_tracker.record_delivery_of(self)
        end
      rescue
        errored!
        raise
      end
    end
  end

  def sanitized_request
    if headers = request&.dig("headers")&.except("X-Webhook-Signature")
      { headers: headers }
    end
  end

  def response_summary
    if response.present?
      { code: response[:code], error: response[:error] }
    end
  end

  def failed?
    (errored? || completed?) && !succeeded?
  end

  def succeeded?
    completed? && response[:error].blank? && response[:code].between?(200, 299)
  end

  private
    def next_attempt_at
      Time.iso8601(request[:next_attempt_at]) if request[:next_attempt_at]
    end

    def retry_deadline
      Time.iso8601(request[:first_attempt_at]) + RETRY_WINDOW
    end

    def retryable_response?
      RETRY_ERRORS.include?(response[:error].to_s) || response[:code].to_i.between?(500, 599)
    end

    def earlier_delivery_pending?
      card = event.card
      events_on_card = Event.where(eventable: card).or(
        Event.where(eventable_type: "Comment", eventable_id: Comment.where(card_id: card.id).select(:id))
      )
      predecessors = webhook.deliveries.where(state: [ :pending, :in_progress ], event_id: events_on_card.select(:id))
        .where("created_at < :time OR (created_at = :time AND id < :id)", time: created_at, id: id)
      predecessors.in_progress.where(updated_at: ..STALLED_AFTER.ago).find_each(&:recover)
      predecessors.exists?
    end

    def perform_request
      if resolved_ip.nil?
        { error: :private_uri }
      else
        request = Net::HTTP::Post.new(uri, self.request[:headers]).tap { |request| request.body = self.request[:payload] }

        @request_deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2 * ENDPOINT_TIMEOUT
        response = http.request(request) do |net_http_response|
          stream_body_with_limit(net_http_response)
        end

        { code: response.code.to_i }
      end
    rescue ResponseTooLarge
      { error: :response_too_large }
    rescue Surfguard::Unresolvable, Resolv::ResolvTimeout, Resolv::ResolvError, SocketError
      { error: :dns_lookup_failed }
    rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ETIMEDOUT
      { error: :connection_timeout }
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET
      { error: :destination_unreachable }
    rescue OpenSSL::SSL::SSLError
      { error: :failed_tls }
    end

    def stream_body_with_limit(response)
      bytes_read = 0
      response.read_body do |chunk|
        raise Net::ReadTimeout if Process.clock_gettime(Process::CLOCK_MONOTONIC) > @request_deadline
        bytes_read += chunk.bytesize
        raise ResponseTooLarge if bytes_read > MAX_RESPONSE_SIZE
      end
    end

    def resolved_ip
      return @resolved_ip if defined?(@resolved_ip)
      @resolved_ip = Surfguard.resolve_public_ips(uri.host).first
    end

    def uri
      @uri ||= URI(webhook.url)
    end

    def http
      Net::HTTP.new(uri.host, uri.port).tap do |http|
        http.ipaddr = resolved_ip
        http.use_ssl = (uri.scheme == "https")
        http.open_timeout = ENDPOINT_TIMEOUT
        http.read_timeout = ENDPOINT_TIMEOUT
      end
    end

    def headers
      {
        "User-Agent" => USER_AGENT,
        "Content-Type" => content_type,
        "X-Webhook-Signature" => signature,
        "X-Webhook-Timestamp" => event.created_at.utc.iso8601
      }
    end

    def signature
      OpenSSL::HMAC.hexdigest("SHA256", webhook.signing_secret, payload)
    end

    def content_type
      if webhook.for_campfire?
        "text/html"
      elsif webhook.for_basecamp?
        "application/x-www-form-urlencoded"
      else
        "application/json"
      end
    end

    def payload
      @payload ||= if webhook.for_basecamp?
        { content: render_payload(formats: :html) }.to_query
      elsif webhook.for_campfire?
        render_payload(formats: :html)
      elsif webhook.for_slack?
        slack_payload
      else
        render_payload(formats: :json)
      end
    end

    def render_payload(**options)
      webhook.renderer.render(layout: false, template: "webhooks/event", assigns: { event: event }, **options).strip
    end

    def convert_html_to_mrkdwn(html)
      document = Nokogiri::HTML5(html)

      document.css("a").each do |a|
        a.replace("<#{a["href"].strip}|#{a.text}>") if a["href"].present?
      end

      document.css("b").each do |b|
        b.replace("*#{b.text}*")
      end

      document.css("i").each do |i|
        i.replace("_#{i.text}_")
      end

      document.text
    end

    def slack_payload
      text = event.description_for(nil).to_plain_text
      url = polymorphic_url(event.eventable, base_url_options.merge(script_name: account.slug))

      { text: "#{text} <#{url}|Open in Fizzy>" }.to_json
    end

    def base_url_options
      Rails.application.routes.default_url_options.presence ||
        Rails.application.config.action_mailer.default_url_options
    end
end
