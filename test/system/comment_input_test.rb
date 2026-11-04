require "application_system_test_case"

class CommentInputTest < ApplicationSystemTestCase
  setup do
    sign_in_as(users(:david))
    @card = cards(:layout)
    visit card_url(@card)
  end

  test "pasting into an empty comment enables posting and saves the text" do
    within(".comment--new form") { assert_button "Post", disabled: true }
    paste_text(focus_editor, "Comentario pegado en una sola operación")

    within(".comment--new form") do
      assert_button "Post", disabled: false
      click_button "Post"
    end

    assert_selector ".comment:not(.comment--new) .lexxy-content", text: "Comentario pegado en una sola operación"
    within(".comment--new form") { assert_button "Post", disabled: true }
    assert_equal "Comentario pegado en una sola operación", @card.comments.last.body.to_plain_text
  end

  test "inserting text without key events enables posting and clearing disables it" do
    editor = focus_editor
    page.driver.browser.execute_cdp("Input.insertText", text: "Comentario dictado")

    assert_selector ".comment--new lexxy-editor", text: "Comentario dictado"
    within(".comment--new form") { assert_button "Post", disabled: false }

    editor.send_keys([ :control, "a" ], :backspace)
    assert_no_selector ".comment--new lexxy-editor", text: "Comentario dictado"
    within(".comment--new form") { assert_button "Post", disabled: true }
  end

  test "the first typed character enables posting" do
    focus_editor.send_keys("x")

    within(".comment--new form") { assert_button "Post", disabled: false }
  end

  test "pasting into an existing comment can be saved" do
    click_link "Edit this comment"
    assert_button "Save", disabled: false
    editor = focus_editor(".comment:not(.comment--new) lexxy-editor [contenteditable='true']")
    editor.send_keys([ :control, "a" ], :backspace)
    paste_text(editor, "Comentario editado por pegado")
    click_button "Save"

    assert_selector ".comment:not(.comment--new) .lexxy-content", text: "Comentario editado por pegado"
    assert_equal "Comentario editado por pegado", comments(:layout_overflowing_david).reload.body.to_plain_text
  end

  private
    def focus_editor(selector = ".comment--new lexxy-editor [contenteditable='true']")
      editor = find(selector)
      scroll_to editor, align: :center
      editor.click(x: 10, y: 10)
      assert_selector "#{selector}:focus"
      editor
    end

    def paste_text(editor, text)
      page.execute_script(<<~JS, editor, text)
        const data = new DataTransfer()
        data.setData("text/plain", arguments[1])
        arguments[0].dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }))
      JS
    end
end
