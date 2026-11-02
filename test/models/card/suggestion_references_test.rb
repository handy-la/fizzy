require "test_helper"

class Card::SuggestionReferencesTest < ActiveSupport::TestCase
  setup do
    @previous_key = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = "test-key"
    @card = cards(:logo)
    @related = cards(:layout)
    @suggestion = Card::Suggestion.new(@card, user: users(:david))
    @payloads = []
    Current.user = users(:david)
  end

  teardown do
    RubyLLM.config.openai_api_key = @previous_key
  end

  test "the model can read a linked card and use the tool result in its reply" do
    @related.update!(description: "La entrega requiere validar la impresora")
    @related.comments.create!(creator: users(:kevin), body: "Validación pendiente en Android")
    @related.steps.create!(content: "Revisar recibo", completed: false)
    cite(@related)
    @card.comments.create!(creator: users(:kevin), body: '<a href="mailto:soporte@example.com">Soporte</a>')
    stub_read(@related.number)

    assert_no_difference -> { Comment.count } do
      assert_equal "Confirma la validación de la impresora.", @suggestion.comment
    end

    initial = JSON.parse(@payloads.first.fetch("messages").last.fetch("content"))
    assert_includes initial.fetch("referenced_cards"), @related.number
    refute_includes @payloads.first.to_json, "La entrega requiere validar la impresora"
    context = tool_context
    assert_equal @related.title, context.fetch("title")
    assert_equal "La entrega requiere validar la impresora", context.fetch("description")
    assert_includes context.fetch("comments").map { |comment| comment.fetch("body") }, "Validación pendiente en Android"
    assert_includes context.fetch("steps"), { "content" => "Revisar recibo", "completed" => false }
    assert_equal @related.column.name, context.fetch("status")
  end

  test "the model can reply without reading a cited card" do
    cite(@related)
    @related.update!(description: "Contenido que no se debe cargar sin consulta")
    stub_provider { completion({ content: "De acuerdo." }) }

    assert_equal "De acuerdo.", @suggestion.comment
    assert_equal 1, @payloads.size
    assert @payloads.first.fetch("tools").any?
    assert_equal "auto", @payloads.first.fetch("tool_choice")
    refute_includes @payloads.first.to_json, "Contenido que no se debe cargar sin consulta"
  end

  test "plain card numbers and relative links are readable" do
    @card.comments.create!(creator: users(:kevin), body: "Consultar ##{@related.number}")
    stub_read(@related.number)
    @suggestion.comment
    assert_equal @related.title, tool_context.fetch("title")

    @card.comments.destroy_all
    cite(@related, relative: true)
    @payloads.clear
    @suggestion.comment
    assert_equal @related.title, tool_context.fetch("title")
  end

  test "an unreferenced card cannot be read even when the model requests it" do
    cite(cards(:text))
    stub_read(@related.number)

    @suggestion.comment

    assert tool_context.key?("error")
    refute_includes @payloads.last.to_json, @related.title
  end

  test "a cited private board and a draft by another user stay unreadable" do
    @related.update!(board: boards(:private), column: nil)
    cite(@related)
    stub_read(@related.number)
    @suggestion.comment
    assert tool_context.key?("error")
    refute_includes @payloads.last.to_json, @related.title

    @related.update!(board: boards(:writebook), status: :drafted, creator: users(:kevin))
    @payloads.clear
    @suggestion.comment
    assert tool_context.key?("error")
    refute_includes @payloads.last.to_json, @related.title
  end

  test "external and other-account links do not become local card references" do
    cite(@related, host: "elsewhere.example")
    cite(cards(:paycheck)) # Same number as layout, but another account.
    stub_provider { completion({ content: "¿Qué tarjeta necesitas consultar?" }) }

    @suggestion.comment

    context = JSON.parse(@payloads.first.fetch("messages").last.fetch("content"))
    assert_empty context.fetch("referenced_cards")
    assert_empty @payloads.first.fetch("tools", [])
  end

  test "reading a related card does not allow following its own references" do
    cite(@related)
    @related.comments.create!(creator: users(:kevin), body: "Consultar ##{cards(:text).number}")
    stub_provider do |payload|
      case payload.fetch("messages").count { |message| message["role"] == "tool" }
      when 0 then tool_call(@related.number)
      when 1 then tool_call(cards(:text).number)
      else completion({ content: "¿Puedes aclarar el siguiente paso?" })
      end
    end

    @suggestion.comment

    assert tool_context.key?("error")
    refute_includes @payloads.last.to_json, cards(:text).title
  end

  test "related history exceeding the context budget is rejected without truncation" do
    cite(@related)
    @related.comments.create!(creator: users(:kevin), body: "x" * Card::Suggestion::CONTEXT_LIMIT)
    stub_read(@related.number)

    assert_raises(Card::Suggestion::ContextTooLarge) { @suggestion.comment }
    assert_equal 1, @payloads.size
  end

  test "repeated tool calls are bounded" do
    cite(@related)
    stub_provider do
      assert_operator @payloads.size, :<=, 6, "La generación debe detener las consultas repetidas"
      tool_call(@related.number)
    end

    assert_raises(Card::Suggestion::IncompleteResponse) { @suggestion.comment }
    assert_operator @payloads.size, :<=, 6
  end

  private
    def cite(card, relative: false, host: "example.com")
      path = "/#{card.account.external_account_id}/cards/#{card.number}"
      url = relative ? path : "https://#{host}#{path}?view=card#comments"
      @card.comments.create!(creator: users(:kevin), body: %(<p>Ver <a href="#{url}">tarjeta relacionada</a></p>))
    end

    def stub_provider(&block)
      stub_request(:post, "https://api.fireworks.ai/inference/v1/chat/completions").to_return do |request|
        payload = JSON.parse(request.body)
        @payloads << payload
        block.call(payload)
      end
    end

    def stub_read(number)
      stub_provider do |payload|
        if payload.fetch("messages").any? { |message| message["role"] == "tool" }
          completion({ content: "Confirma la validación de la impresora." })
        else
          tool_call(number)
        end
      end
    end

    def tool_call(number)
      completion({ content: nil, tool_calls: [ { id: "read_#{@payloads.size}", type: "function",
        function: { name: "read_referenced_card", arguments: { number: number }.to_json } } ] }, reason: "tool_calls")
    end

    def completion(message, reason: "stop")
      { headers: { "Content-Type" => "application/json" }, body: {
        id: "suggestion", object: "chat.completion", model: RubyLLM.config.default_model,
        choices: [ { index: 0, message: { role: "assistant" }.merge(message), finish_reason: reason } ],
        usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 }
      }.to_json }
    end

    def tool_context
      JSON.parse(@payloads.last.fetch("messages").reverse.find { |message| message["role"] == "tool" }.fetch("content"))
    end
end
