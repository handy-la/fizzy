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

  # The OAuth client whose grant registered this subscription. It delivers to
  # the app's own device or install, so it is the app's plumbing and ends with
  # the identity's last grant to that client (Identity::AccessToken). Sessions
  # and personal access tokens register none.
  belongs_to :oauth_client, class_name: "Oauth::Client", optional: true

  # Delivery is where an app's subscription could outlive the app, so this is
  # the guarantee: one delivers only while the user's identity holds an
  # unlapsed grant to its app. That covers every way the two come apart (the
  # grant ending, lapsing before the sweep, the user leaving the account or
  # moving to another identity, a claim racing the last grant's end), where
  # the cleanup on grant destroy only finds what the identity still reaches.
  # The grant must also be one Fizzy honors (Oauth::Availability): while
  # OAuth is dark, or connecting apps is in preview and the user isn't a
  # previewer, an app whose tokens are refused gets no notifications either.
  #
  # An account-bound grant reaches only its own account, so only it, or a grant
  # bound to no account, keeps a subscription in that account delivering: once
  # the app's grant for one account ends, a grant it holds for another account
  # doesn't carry that account's notifications.
  scope :deliverable_to, ->(user) do
    grants = Identity::AccessToken.grants.unlapsed.where(identity_id: user.identity_id, account_id: [ nil, user.account_id ], oauth_client: Oauth::Availability.accepted_clients)

    where(oauth_client_id: nil).or \
      where(oauth_client_id: (!Oauth::Availability.connected_apps_preview? || Oauth::Availability.admits?(user.identity) ? grants : grants.none).select(:oauth_client_id))
  end

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

  # Whoever registers an endpoint last owns it. An app that registers a fresh
  # OAuth client on reconnect keeps a device subscription it registered under
  # the old one, so it doesn't go when the old client's grant ends.
  def claim_for(oauth_client)
    update_column :oauth_client_id, oauth_client&.id unless oauth_client_id == oauth_client&.id
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
