# Handy runs this Fizzy for agents: creating a card or commenting on it does not
# subscribe anyone. A person watches a card only by pressing its watch button.
module Card::Watchable
  extend ActiveSupport::Concern

  included do
    has_many :watches, dependent: :destroy
    has_many :watchers, -> { active.merge(Watch.watching) }, through: :watches, source: :user
  end

  def watched_by?(user)
    watch_for(user)&.watching?
  end

  def watch_for(user)
    watches.find_by(user: user)
  end

  def watch_by(user)
    watches.where(user: user).first_or_create.update!(watching: true)
  end

  def unwatch_by(user)
    watches.where(user: user).first_or_create.update!(watching: false)
  end
end
