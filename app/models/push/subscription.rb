class Push::Subscription < ApplicationRecord
  MAX_PER_USER = 5
  class LimitExceeded < StandardError; end

  PERMITTED_ENDPOINT_HOSTS = %w[
    jmt17.google.com
    fcm.googleapis.com
    updates.push.services.mozilla.com
    web.push.apple.com
    notify.windows.com
  ].freeze

  belongs_to :account, default: -> { user.account }
  belongs_to :user
  belongs_to :session, optional: true

  before_validation :set_endpoint_digest

  scope :active, -> { joins(:session) }

  validates :endpoint, presence: true
  validates :client_id, length: { maximum: 64 }, allow_nil: true
  validate :validate_endpoint_url
  before_create :enforce_user_quota

  def self.register_for(user, **attributes)
    transaction do
      # Acquire a write lock before reading, including on SQLite.
      User.where(id: user.id).update_all("updated_at = updated_at")
      subscriptions = user.push_subscriptions
      subscription = subscriptions.find_by(endpoint: attributes[:endpoint])
      if attributes[:client_id].present?
        previous = subscriptions.where(client_id: attributes[:client_id])
        subscription ||= previous.first
        previous.where.not(id: subscription&.id).destroy_all
      end
      subscription ||= subscriptions.new
      subscription.update!(attributes)
      subscription
    end
  end

  def self.for_endpoint(endpoint)
    find_by(endpoint_digest: Digest::SHA256.hexdigest(endpoint.to_s))
  end

  def authorized_for?(user, session)
    session.present? && user_id == user.id && session_id == session.id && Session.exists?(session.id)
  end

  def matches_keys?(attributes)
    endpoint == attributes[:endpoint] && p256dh_key == attributes[:p256dh_key] && auth_key == attributes[:auth_key]
  end

  def notification(**params)
    WebPush::Notification.new(
      **params,
      badge: user.notifications.unread.count,
      endpoint: endpoint,
      endpoint_ip: resolved_endpoint_ip,
      p256dh_key: p256dh_key,
      auth_key: auth_key,
      verification_url: verification_url
    )
  end

  def resolved_endpoint_ip
    return @resolved_endpoint_ip if defined?(@resolved_endpoint_ip)
    @resolved_endpoint_ip = Surfguard.resolve_public_ips(endpoint_uri&.host).first
  rescue Surfguard::Unresolvable
    # A host that resolves to nothing has no usable public IP, same outcome as
    # one whose only addresses are blocked: no endpoint IP to pin, which fails
    # endpoint validation. Push has no lookup-failed surface to distinguish.
    @resolved_endpoint_ip = nil
  end

  private
    def enforce_user_quota
      User.where(id: user_id).update_all("updated_at = updated_at")
      raise LimitExceeded if self.class.where(user_id: user_id).count >= MAX_PER_USER
    end

    def verification_url
      Rails.application.routes.url_helpers.user_push_subscription_verification_path(
        user, token: signed_id(purpose: :push_delivery), script_name: account.slug
      )
    end

    def set_endpoint_digest
      self.endpoint_digest = Digest::SHA256.hexdigest(endpoint.to_s)
    end

    def endpoint_uri
      @endpoint_uri ||= URI.parse(endpoint) if endpoint.present?
    rescue URI::InvalidURIError
      nil
    end

    def validate_endpoint_url
      if endpoint_uri.nil?
        errors.add(:endpoint, "is not a valid URL")
      elsif endpoint_uri.scheme != "https"
        errors.add(:endpoint, "must use HTTPS")
      elsif !permitted_endpoint_host?
        errors.add(:endpoint, "is not a permitted push service")
      elsif resolved_endpoint_ip.nil?
        errors.add(:endpoint, "resolves to a private or invalid IP address")
      end
    end

    def permitted_endpoint_host?
      host = endpoint_uri&.host&.downcase
      PERMITTED_ENDPOINT_HOSTS.any? { |permitted| host&.end_with?(permitted) }
    end
end
