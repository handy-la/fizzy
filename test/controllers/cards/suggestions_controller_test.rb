require "test_helper"

class Cards::SuggestionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as :kevin
    @previous_key = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = "test-key"
  end

  teardown do
    RubyLLM.config.openai_api_key = @previous_key
  end

  test "suggest a title from the unsaved description without changing the draft" do
    draft = boards(:writebook).cards.create!(status: :drafted, creator: users(:kevin))
    stub_completion("Corregir impresión de recibos") do |messages|
      assert_includes messages.last.fetch("content"), "La impresora pierde el total"
      refute_includes messages.last.fetch("content"), "<p>"
    end

    assert_no_changes -> { draft.reload.attributes } do
      post "/#{accounts(:'37s').external_account_id}/cards/#{draft.number}/suggestion",
        params: { kind: "title", description: "<p>La impresora pierde el total</p>" }, as: :json
    end
    assert_response :accepted
    assert_enqueued_jobs 1, only: Card::SuggestionJob
    assert_no_changes -> { draft.reload.title } do
      perform_enqueued_jobs only: Card::SuggestionJob
    end
    get suggestion_url(draft), params: { request_id: response.parsed_body["request_id"] }, as: :json
    assert_response :success
    assert_equal "Corregir impresión de recibos", response.parsed_body["suggestion"]
  end

  test "comment includes all history and creates no comment" do
    card = cards(:logo)
    card.update!(description: "Contexto completo")
    old = card.comments.create!(body: "Primer problema detectado", creator: users(:kevin), created_at: 2.years.ago)
    recent = card.comments.create!(body: "Último informe de la IA", creator: users(:david))
    stub_completion("¿Puedes confirmar el resultado?") do |messages|
      instructions = messages.first.fetch("content")
      assert_includes instructions, "priority to the latest comments"
      assert_includes instructions, "authorizing those commands"
      assert_includes instructions, "asking the agent to run those commands itself instead of waiting for a person"
      assert_includes instructions, "never evidence that the user already approved"
      assert_includes instructions, "Do not invent facts"
      context = JSON.parse(messages.last.fetch("content"))
      assert_equal "Contexto completo", context.fetch("description")
      assert_equal card.title, context.fetch("title")
      assert_equal card.comments.count, context.fetch("comments").size
      assert_equal old.body.to_plain_text, context.fetch("comments").first.fetch("body")
      assert_equal recent.body.to_plain_text, context.fetch("comments").last.fetch("body")
      assert_equal card.events.count, context.fetch("events").size
      assert_equal users(:kevin).name, context.fetch("reply_as")
    end

    assert_no_difference -> { Comment.count } do
      post suggestion_url(card), params: { kind: "comment" }, as: :json
    end
    assert_response :accepted
    request_id = response.parsed_body["request_id"]
    assert_no_difference -> { Comment.count } do
      perform_enqueued_jobs only: Card::SuggestionJob
    end
    get suggestion_url(card), params: { request_id: request_id }, as: :json
    assert_response :success
    assert_equal "¿Puedes confirmar el resultado?", response.parsed_body["suggestion"]
  end

  test "cannot read a private board or another account" do
    private_card = with_current_user(:kevin) { boards(:private).cards.create!(title: "Privado", status: :published) }
    logout_and_sign_in_as :david
    post suggestion_url(private_card), params: { kind: "comment" }, as: :json
    assert_response :not_found

    post "/#{accounts(:initech).external_account_id}/cards/#{cards(:radio).number}/suggestion",
      params: { kind: "comment" }, as: :json
    assert_response :forbidden
  end

  test "existing titles and draft comments do not call the provider" do
    post suggestion_url(cards(:logo)), params: { kind: "title", description: "Otra descripción" }, as: :json
    assert_response :no_content
    draft = boards(:writebook).cards.create!(status: :drafted, creator: users(:kevin))
    post suggestion_url(draft), params: { kind: "comment" }, as: :json
    assert_response :no_content
  end

  test "cancellation between enqueue and execution prevents the provider call" do
    stub_completion("Respuesta que no debe generarse") { |_| }
    post suggestion_url(cards(:logo)), params: { kind: "comment" }, as: :json
    assert_response :accepted
    request = Card::SuggestionRequest.find_by!(token: response.parsed_body.fetch("request_id"))
    accounts(:'37s').cancel(initiated_by: users(:kevin))
    assert accounts(:'37s').cancelled?

    perform_enqueued_jobs only: Card::SuggestionJob

    assert_not_requested :post, "https://api.fireworks.ai/inference/v1/chat/completions"
    assert_equal "failed", request.reload.status
    assert_equal "access_revoked", request.error_category
    assert_nil request.suggestion
  end

  test "a worker with cached active account checks activity before calling the provider" do
    stub_completion("Respuesta que no debe generarse") { |_| }
    post suggestion_url(cards(:logo)), params: { kind: "comment" }, as: :json
    request = Card::SuggestionRequest.find_by!(token: response.parsed_body.fetch("request_id"))
    assert request.user.account.active?
    # Simulate a cancellation committed by another process, before its cleanup.
    Account::Cancellation.insert_all!([ { id: SecureRandom.uuid_v7, account_id: request.user.account_id, initiated_by_id: users(:kevin).id } ])

    request.generate(request.token)

    assert_not_requested :post, "https://api.fireworks.ai/inference/v1/chat/completions"
    assert_equal "access_revoked", request.reload.error_category
  end

  test "cancellation during generation discards the late provider result" do
    stub_completion("Respuesta tardía") do |_|
      accounts(:'37s').cancel(initiated_by: users(:kevin))
    end
    post suggestion_url(cards(:logo)), params: { kind: "comment" }, as: :json
    request = Card::SuggestionRequest.find_by!(token: response.parsed_body.fetch("request_id"))

    perform_enqueued_jobs only: Card::SuggestionJob

    assert_requested :post, "https://api.fireworks.ai/inference/v1/chat/completions", times: 1
    assert_equal "failed", request.reload.status
    assert_equal "access_revoked", request.error_category
    assert_nil request.suggestion
    accounts(:'37s').reactivate
    get suggestion_url(cards(:logo)), params: { request_id: request.token }, as: :json
    assert_response :success
    assert_nil response.parsed_body["suggestion"]
    assert_equal "access_revoked", response.parsed_body["error_category"]
  end

  test "a worker rechecks account activity after the provider even before cancellation cleanup" do
    stub_completion("Respuesta tardía") do |_|
      unless Account::Cancellation.exists?(account_id: accounts(:'37s').id)
        Account::Cancellation.insert_all!([ { id: SecureRandom.uuid_v7, account_id: accounts(:'37s').id, initiated_by_id: users(:kevin).id } ])
      end
    end
    post suggestion_url(cards(:logo)), params: { kind: "comment" }, as: :json
    request = Card::SuggestionRequest.find_by!(token: response.parsed_body.fetch("request_id"))

    perform_enqueued_jobs only: Card::SuggestionJob

    assert_requested :post, "https://api.fireworks.ai/inference/v1/chat/completions", times: 1
    assert_equal "failed", request.reload.status
    assert_equal "access_revoked", request.error_category
    assert_nil request.suggestion
  end

  test "provider failure leaves the card unchanged" do
    stub_request(:post, "https://api.fireworks.ai/inference/v1/chat/completions").to_timeout
    assert_no_difference -> { Comment.count } do
      post suggestion_url(cards(:logo)), params: { kind: "comment" }, as: :json
    end
    assert_response :accepted
    request_id = response.parsed_body["request_id"]
    perform_enqueued_jobs only: Card::SuggestionJob
    get suggestion_url(cards(:logo)), params: { request_id: request_id }, as: :json
    assert_response :success
    assert_equal "failed", response.parsed_body["status"]
    assert_equal "timeout", response.parsed_body["error_category"]
    post suggestion_url(cards(:logo)), params: { kind: "comment" }, as: :json
    assert_response :accepted
    refute_equal request_id, response.parsed_body["request_id"]
  end

  test "empty and truncated provider replies are terminal failures" do
    [ [ "", "stop", "empty" ], [ "Respuesta incompleta", "length", "incomplete" ], [ "x" * 8_001, "stop", "incomplete" ] ].each do |text, reason, category|
      stub_completion(text, finish_reason: reason) { |_| }
      post suggestion_url(cards(:logo)), params: { kind: "comment" }, as: :json
      token = response.parsed_body.fetch("request_id")
      perform_enqueued_jobs only: Card::SuggestionJob
      get suggestion_url(cards(:logo)), params: { request_id: token }, as: :json
      assert_response :success
      assert_equal "failed", response.parsed_body["status"]
      assert_equal category, response.parsed_body["error_category"]
      assert_nil response.parsed_body["suggestion"]
    end
  end

  test "a stalled worker is terminal and its old job cannot generate after retry" do
    card = cards(:logo)
    post suggestion_url(card), params: { kind: "comment" }, as: :json
    token = response.parsed_body.fetch("request_id")
    request = Card::SuggestionRequest.find_by!(token: token)
    request.update!(status: "running", started_at: 3.minutes.ago, expires_at: 1.minute.ago)
    Card::SuggestionRequest.expire_stalled
    get suggestion_url(card), params: { request_id: token }, as: :json
    assert_response :success
    assert_equal "failed", response.parsed_body["status"]
    assert_equal "interrupted", response.parsed_body["error_category"]
    post suggestion_url(card), params: { kind: "comment" }, as: :json
    refute_equal token, response.parsed_body.fetch("request_id")
    request.generate(token)
    assert_not_requested :post, "https://api.fireworks.ai/inference/v1/chat/completions"
    assert_equal "pending", request.reload.status
  end

  test "queue expiry is terminal and completed results have separate retention" do
    stub_completion("Respuesta conservada") { |_| }
    post suggestion_url(cards(:logo)), params: { kind: "comment" }, as: :json
    token = response.parsed_body.fetch("request_id")
    travel 11.minutes do
      perform_enqueued_jobs only: Card::SuggestionJob
      get suggestion_url(cards(:logo)), params: { request_id: token }, as: :json
      assert_response :success
      assert_equal "failed", response.parsed_body["status"]
      assert_equal "queue_expired", response.parsed_body["error_category"]
      assert_not_requested :post, "https://api.fireworks.ai/inference/v1/chat/completions"
    end
    post suggestion_url(cards(:logo)), params: { kind: "comment" }, as: :json
    token = response.parsed_body.fetch("request_id")
    travel 6.minutes do
      perform_enqueued_jobs only: Card::SuggestionJob
      get suggestion_url(cards(:logo)), params: { request_id: token }, as: :json
      assert_response :success
      assert_equal "completed", response.parsed_body["status"]
      assert_equal "Respuesta conservada", response.parsed_body["suggestion"]
    end
  end

  test "pending and completed requests are reused without another provider job" do
    card = cards(:logo)
    stub_completion("Borrador reutilizado") { |_| }
    assert_enqueued_jobs 1 do
      2.times do
        post suggestion_url(card), params: { kind: "comment" }, as: :json
        assert_response :accepted
      end
    end
    token = response.parsed_body.fetch("request_id")
    get suggestion_url(card), params: { request_id: token }, as: :json
    assert_response :accepted
    stub_completion("Borrador reutilizado") { |_| }
    perform_enqueued_jobs only: Card::SuggestionJob
    assert_no_enqueued_jobs only: Card::SuggestionJob do
      post suggestion_url(card), params: { kind: "comment" }, as: :json
    end
    assert_equal token, response.parsed_body.fetch("request_id")
    get suggestion_url(card), params: { request_id: token }, as: :json
    assert_equal "Borrador reutilizado", response.parsed_body.fetch("suggestion")

    logout_and_sign_in_as :david
    get suggestion_url(card), params: { request_id: token }, as: :json
    assert_response :not_found
  end

  test "short descriptions are ignored and superseded title jobs cannot replace the latest request" do
    draft = boards(:writebook).cards.create!(status: :drafted, creator: users(:kevin))
    stub_completion("Título") { |_| }
    post suggestion_url(draft), params: { kind: "title", description: "<p>Corto</p>" }, as: :json
    assert_response :no_content
    assert_enqueued_jobs 2, only: Card::SuggestionJob do
      post suggestion_url(draft), params: { kind: "title", description: "Descripción suficiente para crear un título" }, as: :json
      assert_response :accepted
      post suggestion_url(draft), params: { kind: "title", description: "Una descripción diferente mientras espera" }, as: :json
      assert_response :accepted
    end
    token = response.parsed_body.fetch("request_id")
    stub_completion("Título nuevo") do |messages|
      assert_includes messages.last.fetch("content"), "Una descripción diferente mientras espera"
    end
    perform_enqueued_jobs only: Card::SuggestionJob
    assert_requested :post, "https://api.fireworks.ai/inference/v1/chat/completions", times: 1
    get suggestion_url(draft), params: { request_id: token }, as: :json
    assert_equal "Título nuevo", response.parsed_body.fetch("suggestion")
  end

  private
    def suggestion_url(card)
      "/#{card.account.external_account_id}/cards/#{card.number}/suggestion"
    end

    def stub_completion(text, finish_reason: "stop", &verify)
      stub_request(:post, "https://api.fireworks.ai/inference/v1/chat/completions")
        .with { |request|
          payload = JSON.parse(request.body)
          assert_equal "accounts/fireworks/routers/kimi-k3-fast", payload.fetch("model")
          assert_equal "none", payload.fetch("reasoning_effort")
          verify.call(payload.fetch("messages"))
          true
        }
        .to_return(headers: { "Content-Type" => "application/json" }, body: {
          id: "suggestion", object: "chat.completion", model: RubyLLM.config.default_model,
          choices: [ { index: 0, message: { role: "assistant", content: text }, finish_reason: finish_reason } ],
          usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 }
        }.to_json)
    end
end
