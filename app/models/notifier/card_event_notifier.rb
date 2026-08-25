class Notifier::CardEventNotifier < Notifier
  delegate :creator, to: :source
  delegate :board, to: :card

  private
    def recipients
      case source.action
      when "card_assigned"
        source.assignees.excluding(creator)
      when "card_published"
        card.assignees.excluding(creator)
      when "card_sent_back_to_triage", "card_postponed", "card_auto_postponed", "card_closed"
        User.none
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
