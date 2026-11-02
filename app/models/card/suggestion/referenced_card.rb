class Card::Suggestion::ReferencedCard < RubyLLM::Tool
  description "Read a card cited in the current card's comments, including its description, status, steps and full comment history. Read only when useful for the reply."
  parameter :number, type: :integer, description: "A card number from referenced_cards"

  def self.tool_name
    "read_referenced_card"
  end

  def initialize(user:, numbers:)
    @user, @numbers = user, numbers
  end

  def execute(number:)
    @user.reload
    if @numbers.include?(number) && @user.active? && @user.account.reload.active?
      if card = @user.accessible_cards.where(account_id: @user.account_id).find_by(number: number)
        return Card::Suggestion::Context.new(card).to_h
      end
    end
    { error: "Card unavailable. Use only referenced_cards that you can access; ask for clarification if needed." }
  end
end
