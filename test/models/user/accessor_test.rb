require "test_helper"

class User::AccessorTest < ActiveSupport::TestCase
  test "accessible cards include published cards and only the members own drafts" do
    own_draft = boards(:writebook).cards.create!(creator: users(:david), status: :drafted)
    other_draft = boards(:writebook).cards.create!(creator: users(:jz), status: :drafted)
    Current.user = users(:kevin)

    assert_includes users(:david).accessible_cards, cards(:text)
    assert_includes users(:david).accessible_cards, own_draft
    assert_not_includes users(:david).accessible_cards, other_draft
    assert_not_includes users(:david).accessible_cards, cards(:unfinished_thoughts)
  end

  test "admins can access other creators drafts only in accessible boards" do
    draft = boards(:writebook).cards.create!(creator: users(:david), status: :drafted)
    Current.user = users(:jz)

    assert_includes users(:kevin).accessible_cards, draft

    boards(:writebook).update! all_access: false
    boards(:writebook).accesses.revoke_from users(:kevin)
    users(:kevin).reload
    assert_not_includes users(:kevin).accessible_cards, draft
  end

  test "new users get added to all_access boards on creation" do
    user = User.create!(account: accounts("37s"), name: "Jorge")

    assert_includes user.boards, boards(:writebook)
    assert_equal user.account.boards.all_access.count, user.boards.count
  end

  test "system user does not get added to boards on creation" do
    system_user = User.create!(account: accounts("37s"), role: "system", name: "Test System User")
    assert_empty system_user.boards
  end

  test "creating a new card draft sets current timestamps" do
    user = users(:david)
    board = boards(:writebook)

    freeze_time do
      card = user.draft_new_card_in(board)

      assert card.persisted?
      assert card.drafted?
      assert_equal user, card.creator
      assert_equal board, card.board
      assert_equal Time.current, card.created_at
      assert_equal Time.current, card.updated_at
      assert_equal Time.current, card.last_active_at
    end
  end

  test "reusing an existing card draft refreshes timestamps" do
    existing_draft = cards(:unfinished_thoughts)
    user = existing_draft.creator
    board = existing_draft.board

    freeze_time do
      card = user.draft_new_card_in(board)

      assert_equal existing_draft, card
      assert_equal Time.current, card.created_at
      assert_equal Time.current, card.updated_at
      assert_equal Time.current, card.last_active_at
    end
  end
end
