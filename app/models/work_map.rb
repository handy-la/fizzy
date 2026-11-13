# Handy #2348: the read-only work map. Every card a person can see on every
# board they can access, in one graph, joined to the execution graph Dédalo
# answers (states, waits, milestones and dependencies). Fizzy owns identity
# and stage; Dédalo owns execution and stays the authority. Nothing here
# writes, and the map never widens what `User#accessible_cards` allows: an
# endpoint the person cannot see keeps no product, number or title.
# Contract: docs/work-map.md.
class WorkMap
  MAX_CARDS = 3_000
  MAX_TITLE = 90

  Product = Data.define(:key, :name, :board_id, :status, :read_at, :error, :truncated)

  Node = Data.define(:card, :product, :execution, :execution_status) do
    def id = "card-#{card.number}"

    def disposition
      if card.closed? then "closed"
      elsif card.column.nil? then "maybe"
      else "column"
      end
    end

    def stage_name
      case disposition
      when "closed" then "Done"
      when "maybe" then "Maybe?"
      else card.column.name
      end
    end
  end

  # An endpoint Fizzy cannot show as a card: `inaccessible` (another board, a
  # draft, anything outside the person's access: no identity at all),
  # `missing` (no such card on a board the person can access) or `postponed`
  # (a Not Now card the person can see: Handy #2412, it is not current work, so
  # it is never a card of the map, only the end of a relation).
  Placeholder = Data.define(:id, :kind, :product, :number)

  Edge = Data.define(:from, :to, :condition, :environment, :channel, :status, :since, :resolved_at)

  attr_reader :user, :max_cards

  def initialize(user:, source: WorkMap::Source.default, max_cards: MAX_CARDS)
    @user = user
    @source = source
    @max_cards = max_cards
  end

  def result
    @result ||= @source.read
  end

  def snapshot
    result.snapshot
  end

  def products
    @products ||= registered_products + unregistered_products
  end

  def nodes
    resolve
    @nodes
  end

  def placeholders
    resolve
    @placeholders.values
  end

  def edges
    resolve
    @edges
  end

  def truncated?
    open_cards.size > max_cards
  end

  private
    def boards
      @boards ||= user.boards.order(:name).to_a
    end

    def board_ids
      @board_ids ||= boards.map(&:id).to_set
    end

    def registry
      @registry ||= Array(snapshot&.products).index_by { |product| product["id"] }
    end

    # Only products whose board the person can access: another product's
    # name, status or existence is not theirs to see.
    def registered_products
      registry.values.select { |product| board_ids.include?(product["board_id"]) }.map do |product|
        Product.new(key: product["id"], name: product["name"], board_id: product["board_id"], status: product["status"],
          read_at: product["read_at"], error: product["error"], truncated: product["truncated"])
      end
    end

    # A board Dédalo does not register (or every board, without the source) is
    # shown as its own product, with the reason it has no execution data.
    def unregistered_products
      registered = registry.values.map { |product| product["board_id"] }.to_set
      status = result.ok? ? "unregistered" : "source_#{result.status}"

      boards.reject { |board| registered.include?(board.id) }.map do |board|
        Product.new(key: "board-#{board.id}", name: board.name, board_id: board.id, status:, read_at: nil, error: nil, truncated: false)
      end
    end

    def products_by_board
      @products_by_board ||= products.index_by(&:board_id)
    end

    # Not Now is not current work (Handy #2412): only open cards outside it.
    def open_cards
      @open_cards ||= base_cards.open.where.missing(:not_now).order(last_active_at: :desc, id: :desc).limit(max_cards + 1).to_a
    end

    def base_cards
      user.accessible_cards.published.preload(:board, :column, :closure, :not_now)
    end

    def resolve
      return if @edges

      cards = open_cards.first(max_cards).index_by(&:number)
      wanted = endpoint_numbers - cards.keys
      # A closed endpoint is context of a dependency and stays a card; a
      # postponed one becomes a reference (`postponed_reference`).
      base_cards.where(number: wanted).each { |card| cards[card.number] ||= card } if wanted.any?

      @placeholders = {}
      @edges = relations.filter_map { |relation, index| edge(relation, index, cards) }
      @nodes = cards.values.reject(&:postponed?).map { |card| node(card) }
    end

    def relations
      Array(snapshot&.relations).each_with_index
    end

    def endpoint_numbers
      relations.flat_map { |relation, _| [ relation["prerequisite"]["card"], relation["dependent"]["card"] ] }.uniq
    end

    def edge(relation, index, cards)
      from = endpoint(relation["prerequisite"], cards, "#{index}-p")
      to = endpoint(relation["dependent"], cards, "#{index}-d")

      # Neither end is a card or a missing reference: the relation says nothing.
      unless silent?(from) && silent?(to)
        [ from, to ].grep(Placeholder).each { |placeholder| @placeholders[placeholder.id] ||= placeholder }
        Edge.new(from: id_of(from), to: id_of(to), condition: relation["condition"], environment: relation["environment"],
          channel: relation["channel"], status: relation["status"], since: relation["since"], resolved_at: relation["resolved_at"])
      end
    end

    # Card numbers are unique per account, not per Dédalo: a reference is this
    # card only when its product's board is the card's board.
    def endpoint(reference, cards, slot)
      card = cards[reference["card"]]
      if card.nil? || board_of(reference["product"]) != card.board_id then placeholder(reference, slot)
      elsif card.postponed? then postponed_reference(card)
      else card
      end
    end

    # The person can see the card, so its product and number may show; its
    # title and stage do not, because it is not work on the map.
    def postponed_reference(card)
      product = products_by_board.fetch(card.board_id)
      Placeholder.new(id: "postponed-#{product.key}-#{card.number}", kind: "postponed", product:, number: card.number)
    end

    def board_of(product_id)
      registry[product_id]&.fetch("board_id")
    end

    def placeholder(reference, slot)
      product = products.find { |candidate| candidate.key == reference["product"] }

      if product && missing_numbers.include?(reference["card"])
        Placeholder.new(id: "missing-#{product.key}-#{reference["card"]}", kind: "missing", product: product, number: reference["card"])
      else
        # One placeholder per relation end, so two relations cannot show that
        # they point at the same hidden card.
        Placeholder.new(id: "hidden-#{slot}", kind: "inaccessible", product: nil, number: nil)
      end
    end

    # Numbers no card of this account has at all. Only these may be called
    # missing; a number that exists elsewhere is hidden, never missing.
    def missing_numbers
      @missing_numbers ||= begin
        numbers = endpoint_numbers
        numbers.to_set - Card.where(account_id: user.account_id, number: numbers).pluck(:number)
      end
    end

    def silent?(endpoint)
      endpoint.is_a?(Placeholder) && endpoint.kind.in?(%w[ inaccessible postponed ])
    end

    def id_of(endpoint)
      endpoint.is_a?(Card) ? "card-#{endpoint.number}" : endpoint.id
    end

    def node(card)
      product = products_by_board.fetch(card.board_id)
      execution = items[[ card.board_id, card.number ]]
      Node.new(card:, product:, execution:, execution_status: execution_status(product, execution))
    end

    def items
      @items ||= Array(snapshot&.items).index_by { |item| [ board_of(item["product"]), item["card"] ] }
    end

    # «Sin información de ejecución» is never «sin bloqueos»: this says why a
    # card has no execution data.
    def execution_status(product, execution)
      if execution then "reported"
      elsif product.status.start_with?("source_") then product.status
      elsif product.status == "unregistered" then "unregistered"
      elsif product.status == "failed" then "product_failed"
      elsif product.status == "partial" || product.truncated then "incomplete"
      else "none_reported"
      end
    end
end
