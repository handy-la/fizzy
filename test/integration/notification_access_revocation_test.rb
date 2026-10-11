require "test_helper"

class NotificationAccessRevocationTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    sign_in_as :kevin
    @user = users(:kevin)
    @board = boards(:writebook)
    @notification = notifications(:logo_assignment_kevin)
    cards(:buy_domain).update_column(:board_id, boards(:private).id)
  end

  test "revocation destroys event and mention notifications before cleanup jobs run" do
    [ @user, users(:david) ].each do |user|
      assert user.notifications.joins(:card).where(cards: { board_id: @board.id }).exists?

      assert_enqueued_with(job: Board::CleanInaccessibleDataJob, args: [ user, @board ]) do
        @board.access_for(user).destroy!
      end

      assert_empty user.notifications.joins(:card).where(cards: { board_id: @board.id })
    end

    assert Notification.exists?(notifications(:buy_domain_sent_back_to_triage_kevin).id)
  end

  test "rolling back revocation restores access and notifications" do
    Access.transaction do
      accesses(:writebook_kevin).destroy!
      assert_not Notification.exists?(@notification.id)
      raise ActiveRecord::Rollback
    end

    assert @board.accessible_to?(@user)
    assert Notification.exists?(@notification.id)
  end

  [ :html, :json ].each do |format|
    test "index filters unread and read notifications as #{format} after cleanup fails" do
      notifications(:layout_commented_kevin).read
      fail_cleanup_after_revocation

      get notifications_path, as: format

      assert_response :success
      assert_notifications_filtered(format)
    end

    test "tray filters unread and read notifications as #{format} after cleanup fails" do
      notifications(:layout_commented_kevin).read
      fail_cleanup_after_revocation

      get tray_notifications_path(include_read: true), as: format

      assert_response :success
      assert_notifications_filtered(format)
    end
  end

  test "reading a stale notification is rejected after revocation" do
    fail_cleanup_after_revocation

    post notification_reading_path(@notification), as: :json
    assert_response :not_found

    delete notification_reading_path(@notification), as: :json
    assert_response :not_found
  end

  test "HTML rendering rechecks access before using a cached notification" do
    with_actionview_partial_caching do
      assert_includes render_notification(:html), "notification_#{@notification.id}"
      fail_cleanup_after_revocation

      assert_empty render_notification(:html).strip
    end
  end

  test "JSON rendering rechecks access before using a cached notification" do
    with_actionview_partial_caching do
      assert_equal @notification.id, JSON.parse(render_notification(:json))["id"]
      fail_cleanup_after_revocation

      assert_empty JSON.parse(render_notification(:json))
    end
  end

  test "pending push job processes no target after cleanup fails" do
    # Load the board before revocation to detect use of a stale association.
    @notification.card.board.accesses.load
    fail_cleanup_after_revocation

    target = mock("push target")
    target.expects(:process).never
    original_targets = Notification.push_targets
    Notification.push_targets = [ target ]

    Notification::PushJob.perform_now(@notification)
  ensure
    Notification.push_targets = original_targets if original_targets
  end

  test "pending bundle job sends no email after cleanup fails" do
    @user.settings.bundle_email_every_few_hours!
    @user.bundle(@notification)
    bundle = @user.notification_bundles.pending.last
    fail_cleanup_after_revocation

    assert_no_emails do
      Notification::Bundle::DeliverJob.perform_now(bundle)
    end

    assert bundle.reload.delivered?
  end

  test "queued push is discarded when revocation has destroyed the notification" do
    @notification.push_later
    accesses(:writebook_kevin).destroy!

    target = mock("push target")
    target.expects(:process).never
    original_targets = Notification.push_targets
    Notification.push_targets = [ target ]

    perform_enqueued_jobs only: Notification::PushJob
  ensure
    Notification.push_targets = original_targets if original_targets
  end

  test "a mixed bundle delivers only notifications from accessible boards" do
    @user.settings.bundle_email_every_few_hours!
    allowed = notifications(:buy_domain_sent_back_to_triage_kevin)
    allowed.update!(updated_at: @notification.updated_at)
    @user.bundle(@notification)
    bundle = @user.notification_bundles.pending.last
    fail_cleanup_after_revocation

    assert_emails 1 do
      Notification::Bundle::DeliverJob.perform_now(bundle)
    end

    email = ActionMailer::Base.deliveries.last
    [ email.html_part, email.text_part ].each do |part|
      assert_includes part.body.decoded, allowed.card.title
      assert_not_includes part.body.decoded, @board.name
      assert_not_includes part.body.decoded, @notification.card.title
    end
  end

  private
    def fail_cleanup_after_revocation
      # Keep stale rows to test consumers independently of synchronous deletion.
      accesses(:writebook_kevin).delete
      Board.any_instance.stubs(:clean_inaccessible_data_for).raises(RuntimeError, "cleanup failed")

      assert_raises RuntimeError do
        Board::CleanInaccessibleDataJob.perform_now(@user, @board)
      end
      assert Notification.exists?(@notification.id)
    end

    def assert_notifications_filtered(format)
      forbidden = [ @notification, notifications(:layout_commented_kevin) ]
      allowed = notifications(:buy_domain_sent_back_to_triage_kevin)

      if format == :json
        ids = response.parsed_body.pluck("id")
        forbidden.each { |notification| assert_not_includes ids, notification.id }
        assert_includes ids, allowed.id
      else
        forbidden.each { |notification| assert_select "#notification_#{notification.id}", count: 0 }
        assert_select "#notification_#{allowed.id}", count: 1
        assert_not_includes response.body, @board.name
      end
    end

    def render_notification(format)
      with_current_user(:kevin) do
        ApplicationController.render(partial: "notifications/notification", formats: [ format ], locals: { notification: @notification })
      end
    end
end
