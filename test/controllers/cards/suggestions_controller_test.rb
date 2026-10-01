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

  test "provider failure leaves the card unchanged" do
    stub_request(:post, "https://api.fireworks.ai/inference/v1/chat/completions").to_timeout
    assert_no_difference -> { Comment.count } do
      post suggestion_url(cards(:logo)), params: { kind: "comment" }, as: :json
    end
    assert_response :accepted
    request_id = response.parsed_body["request_id"]
    perform_enqueued_jobs only: Card::SuggestionJob
    get suggestion_url(cards(:logo)), params: { request_id: request_id }, as: :json
    assert_response :service_unavailable
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

    def stub_completion(text, &verify)
      stub_request(:post, "https://api.fireworks.ai/inference/v1/chat/completions")
        .with { |request| verify.call(JSON.parse(request.body).fetch("messages")); true }
        .to_return(headers: { "Content-Type" => "application/json" }, body: {
          id: "suggestion", object: "chat.completion", model: RubyLLM.config.default_model,
          choices: [ { index: 0, message: { role: "assistant", content: text }, finish_reason: "stop" } ],
          usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 }
        }.to_json)
    end
end
