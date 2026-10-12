class Webhook < ApplicationRecord
  include Triggerable

  BOARD_LIMIT = 5
  ACCOUNT_LIMIT = 20

  SLACK_WEBHOOK_URL_REGEX = %r{//hooks\.slack\.com/services/T[^\/]+/B[^\/]+/[^\/]+\Z}i
  CAMPFIRE_WEBHOOK_URL_REGEX = %r{/rooms/\d+/\d+-[^\/]+/messages\Z}i
  BASECAMP_CAMPFIRE_WEBHOOK_URL_REGEX = %r{/\d+/integrations/[^\/]+/buckets/\d+/chats/\d+/lines\Z}i

  PERMITTED_SCHEMES = %w[ https ].freeze
  PERMITTED_ACTIONS = %w[
    card_assigned
    card_closed
    card_postponed
    card_auto_postponed
    card_board_changed
    card_published
    card_reopened
    card_sent_back_to_triage
    card_triaged
    card_unassigned
    comment_created
  ].freeze

  has_secure_token :signing_secret

  has_many :deliveries, dependent: :delete_all
  has_one :delinquency_tracker, dependent: :delete

  belongs_to :account, default: -> { board.account }
  belongs_to :board

  serialize :subscribed_actions, type: Array, coder: JSON

  scope :ordered, -> { order(name: :asc, id: :desc) }
  scope :active, -> { where(active: true) }

  before_create :ensure_quota
  after_create :create_delinquency_tracker!

  normalizes :subscribed_actions, with: ->(value) { Array.wrap(value).map(&:to_s).uniq & PERMITTED_ACTIONS }
  normalizes :url, with: -> { it.strip }

  validates :name, presence: true
  validate :validate_url

  def activate
    active? || update(active: true)
  end

  # Writes only this column: a legacy HTTP URL fails validation but must still
  # be deactivated, and no other unvalidated change may be saved with it.
  def deactivate
    update_columns active: false, updated_at: Time.current
  end

  def renderer
    @renderer ||= ApplicationController.renderer.new(script_name: account.slug, https: !Rails.env.local?)
  end

  def for_basecamp?
    url.match? BASECAMP_CAMPFIRE_WEBHOOK_URL_REGEX
  end

  def for_campfire?
    url.match? CAMPFIRE_WEBHOOK_URL_REGEX
  end

  def for_slack?
    url.match? SLACK_WEBHOOK_URL_REGEX
  end

  private
    def ensure_quota
      Account.where(id: account_id).update_all("updated_at = updated_at")
      if account.webhooks.count >= ACCOUNT_LIMIT || board.webhooks.count >= BOARD_LIMIT
        errors.add :base, "Webhook quota reached"
        throw :abort
      end
    end

    def validate_url
      uri = URI.parse(url.presence)

      if PERMITTED_SCHEMES.exclude?(uri.scheme)
        errors.add :url, "must use #{PERMITTED_SCHEMES.to_choice_sentence}"
      end
    rescue URI::InvalidURIError
      errors.add :url, "not a URL"
    end
end
