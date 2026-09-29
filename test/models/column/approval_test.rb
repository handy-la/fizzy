require "test_helper"

class Column::ApprovalTest < ActiveSupport::TestCase
  test "awaiting approval matches the stage name whatever its case and spacing" do
    column = columns(:writebook_review)

    assert_not column.awaiting_approval?

    column.name = " Awaiting Approval "
    assert column.awaiting_approval?
  end

  test "the next card awaiting is the first active card of the column" do
    column = columns(:writebook_on_hold)
    cards(:logo).update_columns(column_id: column.id)

    assert_equal cards(:logo), column.next_card_awaiting

    cards(:logo).update_columns(column_id: columns(:writebook_triage).id)
    assert_nil column.reload.next_card_awaiting
  end
end
