class Notifier::CardEventNotifier < Notifier
  delegate :creator, to: :source
  delegate :board, to: :card

  private
    def recipients
      case source.action
      when "card_assigned"
        source.assignees.excluding(creator)
      when "card_published"
        board.watchers.without(creator, *card.scan_mentionees).including(*card.assignees).uniq
      when "comment_created"
        card.watchers.without(creator, *source.eventable.scan_mentionees)
      when "card_triaged"
        notify_on_entry? ? board.watchers.without(creator) : User.none
      else
        board.watchers.without(creator)
      end
    end

    def notify_on_entry?
      source.particulars.dig("particulars", "notify_on_entry") != false
    end

    def card
      source.eventable
    end
end
