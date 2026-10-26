require "test_helper"

class Card::SuggestionTest < ActiveSupport::TestCase
  setup do
    @previous_key = RubyLLM.config.openai_api_key
    RubyLLM.config.openai_api_key = "test-key"
    @suggestion = Card::Suggestion.new(cards(:logo), user: users(:kevin))
  end

  teardown do
    RubyLLM.config.openai_api_key = @previous_key
  end

  test "title cleans a long provider response and keeps whole words within sixty characters" do
    stub_completion("  **Corregir** / la : impresión de recibos para vendedores\n sin conexión y recuperar todos los totales.  ")

    title = @suggestion.title("<p>La impresora pierde los totales sin conexión</p>")

    assert_equal "Corregir la impresión de recibos para vendedores sin", title
    assert_operator title.length, :<=, 60
    refute_match %r{[*/:]}, title
  end

  test "title removes punctuation Markdown and complete emoji sequences" do
    stub_completion("**/\\_#\"'[]{}():`<>~|“”‘’«» 😀👩🏽‍💻🇲🇽1️⃣❤️\n  Corregir\t impresión   móvil...")

    assert_equal "Corregir impresión móvil", @suggestion.title("La impresión móvil falla")
  end

  test "title sends the description as a labelled field, not as a request to answer" do
    stub_completion("Actualizar textos del landing page")
    @suggestion.title("<p>Ayúdame a cambiar estos textos en el landing page:</p>")

    assert_requested(:post, "https://api.fireworks.ai/inference/v1/chat/completions") do |request|
      user_message = JSON.parse(request.body)["messages"].find { |message| message["role"] == "user" }
      user_message["content"] == { description: "Ayúdame a cambiar estos textos en el landing page:" }.to_json
    end
  end

  test "title preserves sixty characters and discards a following word" do
    title = "á" * 29 + " " + "é" * 30
    stub_completion(title)
    assert_equal title, @suggestion.title("Descripción de la tarjeta")

    stub_completion("#{title} más")
    assert_equal title, @suggestion.title("Descripción de la tarjeta")
  end

  test "title never returns a fragment of an oversized word" do
    stub_completion("Corregir #{'a' * 61}")
    assert_equal "Corregir", @suggestion.title("Descripción de la tarjeta")

    stub_completion("a" * 61)
    assert_equal "", @suggestion.title("Descripción de la tarjeta")
  end

  private
    def stub_completion(text)
      stub_request(:post, "https://api.fireworks.ai/inference/v1/chat/completions")
        .to_return(headers: { "Content-Type" => "application/json" }, body: {
          id: "suggestion", object: "chat.completion", model: RubyLLM.config.default_model,
          choices: [ { index: 0, message: { role: "assistant", content: text }, finish_reason: "stop" } ],
          usage: { prompt_tokens: 10, completion_tokens: 10, total_tokens: 20 }
        }.to_json)
    end
end
