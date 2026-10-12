require "test_helper"

class Card::SuggestionQueueTest < ActiveSupport::TestCase
  setup do
    @previous_key = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = "test-key"
    @url = "https://api.fireworks.ai/inference/v1/chat/completions"
    stub_request(:post, @url).to_timeout
  end

  teardown do
    RubyLLM.config.openai_api_key = @previous_key
  end

  test "account capacity leaves room for other accounts" do
    request_for(users(:kevin))
    request_for(users(:david))
    assert_rejected { request_for(users(:jz)) }
    assert_equal "pending", request_for(users(:mike), cards(:radio)).status
    assert_equal 3, Card::SuggestionRequest.where(status: "pending").count
  end

  test "global capacity includes running work" do
    first = request_for(users(:kevin))
    first.update!(status: "running", expires_at: 2.minutes.from_now)
    request_for(users(:david))
    mike = users(:mike)
    request_for(mike, cards(:radio))
    coworker = mike.account.users.create!(name: "Otro miembro", role: :admin)
    request_for(coworker, cards(:radio))
    other_user, other_card = create_tenant

    assert_rejected { request_for(other_user, other_card) }
    assert_equal 4, Card::SuggestionRequest.where(status: %w[ pending running ]).count
  end

  test "account budget counts failures and repeated use of the same request row" do
    10.times do
      request_for(users(:kevin))
      perform_enqueued_jobs only: Card::SuggestionJob
    end
    assert_requested :post, @url, times: 10
    assert_equal 1, Card::SuggestionRequest.count
    assert_rejected { request_for(users(:kevin)) }
    assert_equal "pending", request_for(users(:mike), cards(:radio)).status

    travel 1.hour + 1.second do
      assert_equal "pending", request_for(users(:kevin)).status
    end
  end

  test "global hourly budget cannot be avoided by rotating accounts" do
    tenants = [ [ users(:kevin), cards(:logo) ], [ users(:mike), cards(:radio) ], create_tenant ]
    10.times do
      tenants.each do |user, card|
        request_for(user, card)
        perform_enqueued_jobs only: Card::SuggestionJob
      end
    end
    assert_requested :post, @url, times: 30
    other_user, other_card = create_tenant
    assert_rejected { request_for(other_user, other_card) }
  end

  test "tenant turns prevent starvation with ninety second provider calls" do
    request_for(users(:kevin))
    request_for(users(:david))
    request_for(users(:mike), cards(:radio))
    coworker = users(:mike).account.users.create!(name: "Otro miembro", role: :admin)
    request_for(coworker, cards(:radio))
    accounts_called = []
    stub_request(:post, @url).to_return do |_request|
      running = Card::SuggestionRequest.find_by!(status: "running")
      accounts_called << running.user.account_id
      # Advance the clock while the real job retains its running slot.
      travel 90.seconds
      { status: 200, headers: { "Content-Type" => "application/json" }, body: {
        id: "suggestion", object: "chat.completion", model: RubyLLM.config.default_model,
        choices: [ { index: 0, message: { role: "assistant", content: "Respuesta" }, finish_reason: "stop" } ],
        usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 }
      }.to_json }
    end

    perform_enqueued_jobs only: Card::SuggestionJob

    assert_equal 4, accounts_called.length
    assert accounts_called.each_cons(2).all? { |left, right| left != right }, accounts_called.inspect
    assert_equal 4, Card::SuggestionRequest.where(status: "completed").count
    assert Card::SuggestionRequest.all.all? { |request| request.started_at - request.requested_at < 10.minutes }
    assert_equal 4, Card::SuggestionAdmission.count if defined?(Card::SuggestionAdmission)
  ensure
    travel_back
  end

  test "a job can initialize the scheduler for already accepted work" do
    request = request_for(users(:kevin))
    Card::SuggestionQueue.delete_all if defined?(Card::SuggestionQueue)

    perform_enqueued_jobs only: Card::SuggestionJob

    assert_equal "timeout", request.reload.error_category
    assert_requested :post, @url, times: 1
  end

  test "expired worker lease recovers another tenant without retrying a charged call" do
    first = request_for(users(:kevin))
    first.update!(status: "running", expires_at: 2.minutes.from_now)
    other = request_for(users(:mike), cards(:radio))
    clear_enqueued_jobs

    travel 3.minutes do
      Card::SuggestionRequest.expire_stalled
      perform_enqueued_jobs only: Card::SuggestionJob
      assert_equal "interrupted", first.reload.error_category
      assert_equal "timeout", other.reload.error_category
      assert_requested :post, @url, times: 1
    end
    assert_equal 2, Card::SuggestionAdmission.count if defined?(Card::SuggestionAdmission)
  end

  private
    def request_for(user, card = cards(:logo))
      Card::SuggestionRequest.request(card, user: user, kind: "comment")
    end

    def assert_rejected
      token_snapshot = Card::SuggestionRequest.pluck(:id, :token, :status)
      assert_no_enqueued_jobs only: Card::SuggestionJob do
        # StandardError keeps these regression candidates runnable on the base,
        # which has no admission error class. Check the concrete type on GREEN.
        error = assert_raises(StandardError) { yield }
        assert_equal "Card::SuggestionQueue::Full", error.class.name
      end
      assert_equal token_snapshot, Card::SuggestionRequest.pluck(:id, :token, :status)
    end

    def create_tenant
      account = Account.create!(name: "Cuenta de prueba")
      account.users.create!(name: "System", role: :system)
      user = account.users.create!(name: "Miembro", role: :admin)
      card = Current.with(user: user, account: account) do
        board = account.boards.create!(name: "Tablero", creator: user, all_access: true)
        board.cards.create!(title: "Tarjeta", status: :published, creator: user)
      end
      [ user, card ]
    end
end
