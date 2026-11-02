class Card::Suggestion::Context
  def initialize(card)
    @card = card
  end

  def to_h
    {
      number: @card.number,
      title: @card.title,
      description: @card.description.to_plain_text,
      board: @card.board.name,
      status: @card.closed? ? "closed" : @card.column&.name || "Maybe?",
      assignees: @card.assignees.map(&:name),
      steps: @card.steps.order(:created_at, :id).map { |step| { content: step.content, completed: step.completed? } },
      comments: comments.map { |comment|
        { author: comment.creator.name, created_at: comment.created_at, body: comment.body.to_plain_text }
      },
      events: @card.events.chronologically.includes(:creator).map { |event|
        { author: event.creator.name, created_at: event.created_at, action: event.action, particulars: event.api_particulars }
      }
    }
  end

  def referenced_card_numbers
    comments.flat_map do |comment|
      fragment = Nokogiri::HTML.fragment(comment.body.body&.to_html.to_s)
      links = fragment.css("a[href]").filter_map { |link| number_from_url(link["href"]) }
      # An external link labelled #42 must not authorize the local card #42.
      fragment.css("a").remove
      text = fragment.text
      urls = URI.extract(text, %w[ http https ])
      links += urls.filter_map { |url| number_from_url(url) }
      urls.each { |url| text = text.gsub(url, "") }
      links + text.scan(/(?<![\p{L}\p{N}_])#([1-9]\d*)\b/).flatten.map(&:to_i)
    end.uniq - [ @card.number ]
  end

  private
    def comments
      @comments ||= @card.comments.chronologically.includes(:creator, :rich_text_body).to_a
    end

    def number_from_url(url)
      uri = URI.parse(url)
      return if uri.scheme && !uri.scheme.in?(%w[ http https ])

      if uri.host
        options = Rails.application.config.action_mailer.default_url_options.to_h.merge(Rails.application.routes.default_url_options)
        host = URI.parse("http://#{options[:host]}").host
        return unless uri.host == host
      end
      if match = uri.path.to_s.match(%r{\A/#{@card.account.external_account_id}/cards/([1-9]\d*)(?:\.json)?/?\z})
        match[1].to_i
      end
    rescue URI::InvalidURIError
      nil
    end
end
