require "application_system_test_case"

# Handy #2304. Contract, regression, coverage and seam: docs/test-audits/handy-2304.md.
class PowerThroughTest < ApplicationSystemTestCase
  MARKER = Card::PendingRequest::MARKER

  setup do
    @board = boards(:writebook)
    Comment.where(card: @board.cards).destroy_all
    ask cards(:text), "❓ ¿Uno o dos?", at: 2.hours.ago
    ask cards(:logo), "❓ ¿Grande o pequeño?", at: 1.hour.ago
    @stages = [ columns(:writebook_triage).id, columns(:writebook_in_progress).id ].join(",")

    sign_in_as(users(:david))
  end

  test "send and next posts the reply once and moves to the next card" do
    visit_queue
    assert_focused_card cards(:text)

    write "Uno."
    send_reply

    assert_focused_card cards(:logo)
    assert_equal [ "Uno." ], replies(cards(:text))
    assert_nil local_storage("comment-#{users(:david).id}-#{cards(:text).id}")
  end

  test "a reply to the last card of an approval stage leaves the editor empty" do
    approval = columns(:writebook_review).tap { it.update!(name: "AWAITING APPROVAL") }
    cards(:text).update!(column: approval)
    visit board_power_through_url(@board, stages: approval.id, card: cards(:text).number)

    write "Uno."
    send_reply

    assert_selector ".power-through__review", text: "Revisar contexto"
    assert_no_selector ".power-through__composer lexxy-editor", text: "Uno."
    assert_button "Enviar y siguiente", disabled: true
    assert_equal [ "Uno." ], replies(cards(:text))
  end

  test "keys typed into the reply never navigate, and outside they do" do
    visit_queue
    write "jk"
    assert_focused_card cards(:text)

    page.execute_script("document.activeElement.blur()")
    find("body").send_keys("j")

    assert_focused_card cards(:logo)
  end

  test "a lost answer and a retry leave a single comment" do
    visit_queue
    write "Uno."
    page.execute_script(<<~JS)
      window.realFetch = window.fetch
      window.fetch = async (url, options) => {
        const response = await window.realFetch(url, options)
        if (options?.method === "POST") throw new TypeError("Failed to fetch")
        return response
      }
    JS

    send_reply
    assert_selector ".power-through__error", text: "No sabemos si tu respuesta se publicó"
    assert_equal [ "Uno." ], replies(cards(:text))

    # The comment that landed changed the card: the first retry warns, the
    # second one reuses the token and gets the same comment back.
    page.execute_script("window.fetch = window.realFetch")
    send_reply
    assert_selector "[data-power-through-composer-target=notice]", text: "cambió mientras escribías"
    send_reply

    assert_focused_card cards(:logo)
    assert_equal [ "Uno." ], replies(cards(:text))
  end

  test "a retry whose earlier attempt landed the edited text moves on without a second comment" do
    visit_queue
    write "Uno."
    page.execute_script(<<~JS)
      window.realFetch = window.fetch
      window.fetch = async (url, options) => {
        if (options?.method !== "POST") return window.realFetch(url, options)
        window.posts = (window.posts || 0) + 1
        if (window.posts === 1) throw new TypeError("Failed to fetch")
        await window.realFetch(url, options)
        throw new TypeError("Failed to fetch")
      }
    JS

    send_reply
    assert_selector ".power-through__error", text: "No sabemos si tu respuesta se publicó"
    find(".power-through__composer lexxy-editor [contenteditable='true']").send_keys(" Dos.")
    send_reply
    assert_selector ".power-through__error", text: "No sabemos si tu respuesta se publicó"
    assert_equal [ "Uno. Dos." ], replies(cards(:text))

    page.execute_script("window.fetch = window.realFetch")
    send_reply
    assert_selector "[data-power-through-composer-target=notice]", text: "cambió mientras escribías"
    send_reply

    assert_focused_card cards(:logo)
    assert_equal [ "Uno. Dos." ], replies(cards(:text))
  end

  test "after changing stages, the next card follows the stages chosen now" do
    visit_queue
    write "Uno."

    find(".power-through__stages summary").click
    uncheck "Triage"
    click_button "Aplicar"
    assert_selector ".power-through__stages summary strong", exact_text: "In progress"
    assert_selector ".power-through__composer lexxy-editor", text: "Uno."

    send_reply

    assert_selector ".power-through__empty"
    assert_selector ".power-through__stages summary strong", exact_text: "In progress"
    assert_equal [ "Uno." ], replies(cards(:text))
  end

  test "a request that changes while someone writes is flagged and the draft is kept" do
    visit_queue
    write "Uno."
    ask cards(:text), "❓ Otra pregunta: ¿y el color?"

    send_reply

    assert_selector "[data-power-through-composer-target=notice]", text: "cambió mientras escribías"
    assert_empty replies(cards(:text))
    assert_selector ".power-through__composer lexxy-editor", text: "Uno."

    send_reply

    assert_focused_card cards(:logo)
    assert_equal [ "Uno." ], replies(cards(:text))
  end

  test "a verdict that cannot be read stops the post and keeps the draft" do
    visit_queue
    write "Uno."
    page.execute_script(<<~JS)
      window.realFetch = window.fetch
      window.fetch = (url, options) => String(url).includes("/power_through/cards/") ? Promise.reject(new TypeError("Failed to fetch")) : window.realFetch(url, options)
    JS

    send_reply

    assert_selector ".power-through__error", text: "no envié tu respuesta"
    assert_focused_card cards(:text)
    assert_empty replies(cards(:text))
    assert_selector ".power-through__composer lexxy-editor", text: "Uno."
  end

  test "text typed while the reply is on its way stays unsent in the editor" do
    visit_queue
    write "Uno."
    page.execute_script(<<~JS)
      window.realFetch = window.fetch
      window.fetch = async (url, options) => {
        if (options?.method === "POST") await new Promise(resolve => setTimeout(resolve, 1500))
        return window.realFetch(url, options)
      }
    JS

    send_reply
    assert_button "Enviar y siguiente", disabled: true
    find(".power-through__composer lexxy-editor [contenteditable='true']").send_keys(" Y algo más.")

    assert_selector "[data-power-through-composer-target=notice]", text: "sigue aquí, sin publicar"
    assert_focused_card cards(:text)
    assert_equal [ "Uno." ], replies(cards(:text))
    assert_includes local_storage("comment-#{users(:david).id}-#{cards(:text).id}"), "Y algo más."
  end

  test "chosen stages are remembered per account, person and board, and a corrupt value is ignored" do
    in_progress = columns(:writebook_in_progress).id
    visit board_power_through_url(@board, stages: in_progress)
    assert_equal [ in_progress ], JSON.parse(local_storage(preferences_key))["stages"]

    open_from_board
    assert_selector ".power-through__stages summary strong", exact_text: "In progress"
    assert_focused_card cards(:text)

    page.execute_script("localStorage.setItem(arguments[0], '{corrupt')", preferences_key)
    open_from_board
    assert_selector ".power-through__stages summary strong", exact_text: "Maybe?, Triage, In progress, On Hold y Review"
    assert_current_path board_power_through_path(@board)
    assert_nil local_storage(preferences_key)
  end

  test "the card page keeps a draft per person and moves the old per-card draft" do
    visit card_url(cards(:layout))
    page.execute_script("localStorage.setItem(arguments[0], '<p>Borrador anterior</p>')", "comment-#{cards(:layout).id}")

    visit card_url(cards(:layout))

    assert_selector ".comment--new lexxy-editor", text: "Borrador anterior"
    assert_nil local_storage("comment-#{cards(:layout).id}")
    assert_equal "<p>Borrador anterior</p>", local_storage("comment-#{users(:david).id}-#{cards(:layout).id}")
  end

  private
    def ask(card, text, at: Time.current)
      card.comments.create!(body: text + MARKER, creator: users(:jz), created_at: at)
    end

    def visit_queue
      visit board_power_through_url(@board, stages: @stages, card: cards(:text).number)
    end

    def open_from_board
      visit board_url(@board)
      find("a[href='#{board_power_through_path(@board)}']").click
    end

    def assert_focused_card(card)
      assert_selector ".power-through__title", text: "##{card.number}"
    end

    def write(text)
      editor = find(".power-through__composer lexxy-editor [contenteditable='true']")
      scroll_to editor, align: :center
      editor.click(x: 10, y: 10)
      editor.send_keys(text)
      assert_button "Enviar y siguiente", disabled: false
    end

    def send_reply
      find(".power-through__composer lexxy-editor [contenteditable='true']").send_keys([ :control, :enter ])
    end

    def replies(card)
      card.comments.reload.where(creator: users(:david)).map { it.body.to_plain_text.strip }
    end

    def local_storage(key)
      page.evaluate_script("localStorage.getItem(arguments[0])", key)
    end

    def preferences_key
      "power-through:v1:#{accounts("37s").external_account_id}:#{users(:david).id}:#{@board.id}"
    end
end
