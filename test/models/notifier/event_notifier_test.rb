require "test_helper"

class Notifier::EventNotifierTest < ActiveSupport::TestCase
  test "for returns the matching notifier class for the event" do
    assert_kind_of Notifier::CardEventNotifier, Notifier.for(events(:logo_published))
  end

  test "generate does not create notifications if the event was system-generated" do
    cards(:logo).drafted!
    events(:logo_published).update!(creator: accounts("37s").system_user)

    assert_no_difference -> { Notification.count } do
      Notifier.for(events(:logo_published)).notify
    end
  end

  test "creates a notification for each watcher, other than the event creator (events)" do
    notifications = Notifier.for(events(:layout_commented)).notify

    assert_equal [ users(:kevin) ], notifications.map(&:user)
  end

  test "creates a notification for each watcher (mentions)" do
    notifications = Notifier.for(events(:layout_commented)).notify

    assert_equal [ users(:kevin) ], notifications.map(&:user)
  end

  test "does not create a notification for access-only users" do
    boards(:writebook).access_for(users(:kevin)).access_only!

    notifications = Notifier.for(events(:layout_commented)).notify

    assert_equal [ users(:kevin) ], notifications.map(&:user)
  end

  test "links to the card" do
    boards(:writebook).access_for(users(:kevin)).watching!

    Notifier.for(events(:logo_assignment_jz)).notify

    assert_equal cards(:logo), Notification.last.source.eventable
  end

  test "assignment events only create a notification for the assignee" do
    boards(:writebook).access_for(users(:jz)).watching!
    boards(:writebook).access_for(users(:kevin)).watching!

    notifications = Notifier.for(events(:logo_assignment_jz)).notify

    assert_equal [ users(:jz) ], notifications.map(&:user)
  end

  test "assignment events do not notify users who are access-only for the board" do
    boards(:writebook).access_for(users(:jz)).watching!
    events(:logo_assignment_jz).update! creator: users(:jz)

    notifications = Notifier.for(events(:logo_assignment_jz)).notify

    assert_empty notifications
  end

  test "assignment events do not notify you if you assigned yourself" do
    boards(:writebook).access_for(users(:david)).watching!

    notifications = Notifier.for(events(:logo_assignment_david)).notify

    assert_empty notifications
  end

  test "default stage entry events do not notify watchers" do
    boards(:writebook).access_for(users(:kevin)).watching!
    event = events(:logo_published)

    %w[ card_sent_back_to_triage card_postponed card_auto_postponed card_closed ].each do |action|
      event.update!(action: action)

      assert_empty Notifier.for(event).notify, "Expected #{action} to be silent"
    end
  end

  test "publishing only notifies assignees, not other board watchers" do
    boards(:writebook).accesses.create!(user: users(:jason), involvement: :watching)

    notifications = Notifier.for(events(:logo_published)).notify

    assert_equal cards(:logo).assignees.sort_by(&:id), notifications.map(&:user).sort_by(&:id)
    assert_not_includes notifications.map(&:user), users(:jason)
  end

  test "don't create notifications on comment for mentionees" do
    users(:david).mentioned_by(users(:kevin), at: cards(:layout))

    assert_no_difference -> { users(:david).notifications.count } do
      Notifier.for(events(:layout_commented)).notify
    end
  end

  test "don't create notifications on comment for mentionees even before mention records exist" do
    comment = cards(:layout).comments.create!(
      body: "Hey #{mention_html_for(users(:kevin))}, what do you think?",
      creator: users(:david)
    )
    event = boards(:writebook).events.create!(
      action: "comment_created", creator: users(:david), eventable: comment
    )

    assert_empty comment.mentionees, "Mention records should not exist yet"

    notifications = Notifier.for(event).notify

    assert_not_includes notifications.map(&:user), users(:kevin)
  end

  test "assignment events notify assignees regardless of involvement level" do
    boards(:writebook).access_for(users(:jz)).access_only!

    notifications = Notifier.for(events(:logo_assignment_jz)).notify

    assert_equal [ users(:jz) ], notifications.map(&:user)
  end

  test "card triage events do not notify watchers when disabled for the destination column" do
    boards(:writebook).access_for(users(:kevin)).watching!
    event = events(:logo_published)
    event.update!(action: "card_triaged", particulars: { particulars: { column: "Quiet", notify_on_entry: false } })

    assert_empty Notifier.for(event).notify
  end

  test "legacy card triage events still notify watchers" do
    boards(:writebook).access_for(users(:kevin)).watching!
    event = events(:logo_published)
    event.update!(action: "card_triaged", particulars: { particulars: { column: "In progress" } })

    assert_equal [ users(:kevin) ], Notifier.for(event).notify.map(&:user)
  end

  private
    def mention_html_for(user)
      ActionText::Attachment.from_attachable(user).to_html
    end
end
