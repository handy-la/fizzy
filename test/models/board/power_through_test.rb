require "test_helper"

# Handy #2304. Contract, regression, coverage and seam: docs/test-audits/handy-2304.md.
class Board::PowerThroughTest < ActiveSupport::TestCase
  MARKER = Card::PendingRequest::MARKER

  setup do
    Current.session = sessions(:david)
    @board = boards(:writebook)
    Comment.where(card: @board.cards).destroy_all
    @at = 2.hours.ago
  end

  test "the default stage is the approval stage when the board has one" do
    approval = columns(:writebook_review).tap { it.update!(name: "AWAITING APPROVAL") }

    assert_equal [ approval.id ], queue.selected_stage_ids
  end

  test "without an approval stage every stage is selected" do
    assert_equal [ "maybe" ] + @board.columns.sorted.ids, queue.selected_stage_ids
  end

  test "deleted or unknown stages are dropped, and nothing valid left means the default" do
    in_progress = columns(:writebook_in_progress)

    assert_equal [ in_progress.id ], queue(stages: [ "deleted", in_progress.id ]).selected_stage_ids
    assert_equal queue.default_stage_ids, queue(stages: "deleted,also-deleted").selected_stage_ids
  end

  test "only cards with a pending or ambiguous request are queued, oldest request first" do
    ask cards(:text), "❓ ¿Uno o dos?"
    ask cards(:logo), "❓ ¿Grande o pequeño?", at: 3.hours.ago
    ask cards(:layout), "📌 Progreso."
    ask cards(:shipping), "❓ ¿Hoy?"
    answer cards(:shipping), "Sí."

    assert_equal [ cards(:logo), cards(:text) ], queue.entries.map(&:card)
  end

  test "the queue is limited to the chosen stages" do
    ask cards(:text), "❓ ¿Uno o dos?"
    ask cards(:logo), "❓ ¿Grande o pequeño?"
    ask cards(:buy_domain), "❓ ¿Qué dominio?"

    assert_equal [ cards(:text) ], queue(stages: columns(:writebook_in_progress).id).entries.map(&:card)
    assert_equal [ cards(:buy_domain) ], queue(stages: "maybe").entries.map(&:card)
  end

  test "cards of another board never join the queue" do
    ask cards(:text), "❓ ¿Uno o dos?"
    cards(:text).update_columns(board_id: boards(:private).id)

    assert_empty queue.entries
  end

  test "another person's draft is not queued for a member" do
    draft = @board.cards.create!(title: "Borrador", creator: users(:kevin), status: :published, column: columns(:writebook_in_progress))
    ask draft, "❓ ¿Lo publico?"
    draft.update!(status: :drafted)

    assert_not_includes queue(user: users(:david)).entries.map(&:card), draft
  end

  test "closed and postponed cards are not queued" do
    ask cards(:text), "❓ ¿Uno o dos?"
    ask cards(:logo), "❓ ¿Grande o pequeño?"
    cards(:text).close
    cards(:logo).postpone

    assert_empty queue.entries
  end

  private
    def queue(stages: nil, user: users(:david))
      Board::PowerThrough.new(board: @board, user:, stage_ids: stages)
    end

    def ask(card, text, at: nil)
      card.comments.create!(body: text + MARKER, creator: users(:jz), created_at: at || (@at += 1.minute))
    end

    def answer(card, text)
      card.comments.create!(body: text, creator: users(:david), created_at: (@at += 1.minute))
    end
end
