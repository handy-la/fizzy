require "application_system_test_case"

class MarkdownPasteTest < ApplicationSystemTestCase
  test "markdown paste adds block spacing" do
    sign_in_as(users(:david))

    visit card_url(cards(:layout))
    paste_markdown("Hello\n\nWorld")

    within("lexxy-editor") do
      assert_selector "p", text: "Hello"
      assert_selector "p br", visible: :all
      assert_selector "p", text: "World"
    end
  end

  test "markdown paste preserves line breaks" do
    sign_in_as(users(:david))

    visit card_url(cards(:layout))
    paste_markdown("Hello\nWorld")

    inner_html = find("lexxy-editor p", text: "Hello").native.property("innerHTML")
    children = Nokogiri::HTML5.fragment(inner_html).children
    assert_pattern do
      children => [
        { name: "span", inner_html: "Hello" },
        { name: "br" },
        { name: "span", inner_html: "World" }
      ]
    end
  end

  private
    def paste_markdown(markdown)
      editor = find(".comment--new lexxy-editor [contenteditable='true']")
      # The floating card dock can cover the center of the editor.
      scroll_to editor, align: :center
      editor.click(x: 10, y: 10)
      assert_selector ".comment--new lexxy-editor [contenteditable='true']:focus"

      page.execute_script(<<~JS, editor, markdown)
        const dt = new DataTransfer();
        dt.setData("text/plain", arguments[1]);
        arguments[0].dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
      JS
    end
end
