require "test_helper"

class ActionTextRenderingTest < ActionView::TestCase
  test "data-action attributes in user content are stripped" do
    malicious_html = <<~HTML
      <p>Click here: <a href="#" data-action="dangerous#action">malicious link</a></p>
    HTML

    content = ActionText::Content.new(malicious_html)
    rendered = content.to_s

    assert_no_match(/data-action/, rendered)
    assert_match(/<a href="#">malicious link<\/a>/, rendered)
  end

  %w[image/png video/mp4].each do |content_type|
    kind = content_type.start_with?("image/") ? "image" : "video"

    test "remote #{kind} requires an explicit external link in rich text and activity" do
      url = "https://tracker.example.test/view.#{kind}?member=123"
      content = ActionText::Content.new(%(<action-text-attachment url="#{url}" content-type="#{content_type}" caption="Example"></action-text-attachment>))
      attachable = content.attachables.sole
      fragment = Nokogiri::HTML.fragment(content.to_s)
      assert_empty fragment.css("img, video, source")
      link = fragment.at_css("a")
      assert_not_nil link
      assert_equal url, link["href"]
      assert_equal "_blank", link["target"]
      assert_includes link["rel"].to_s.split, "noreferrer"
      assert_includes link["rel"].to_s.split, "noopener"
      assert_includes link.text, "comparte tu conexión"

      activity = Nokogiri::HTML.fragment(render(partial: "events/event/attachments/remote_#{kind}", locals: { "remote_#{kind}".to_sym => attachable }))
      assert_empty activity.css("a, img, video, source")
      assert_includes activity.text, kind == "image" ? "Imagen externa bloqueada" : "Video externo bloqueado"
    end

    [ "javascript:alert(1)", "data:image/png;base64,YQ==", "//tracker.example.test/file", "https://user:password@tracker.example.test/file", "image.png", "https://[invalid" ].each do |url|
      test "remote #{kind} does not offer unsafe URL #{url}" do
        content = ActionText::Content.new(%(<action-text-attachment url="#{ERB::Util.html_escape(url)}" content-type="#{content_type}"></action-text-attachment>))
        attachable_class = kind == "image" ? ActionText::Attachables::RemoteImage : ActionText::Attachables::RemoteVideo
        attachable = attachable_class.new(url: url, content_type: content_type)
        fragments = [ content.to_s, render(partial: "events/event/attachments/remote_#{kind}", locals: { "remote_#{kind}".to_sym => attachable }) ]

        fragments.each do |html|
          assert_empty Nokogiri::HTML.fragment(html).css("a[href], img, video, source"), html
        end
      end
    end
  end
end
