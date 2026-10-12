require "test_helper"

class CardDraftPrivacyTest < ActionDispatch::IntegrationTest
  setup do
    @draft = boards(:writebook).cards.create!(creator: users(:david), status: :drafted,
      title: "Private draft title", description: "Private draft description")
    sign_in_as :jz
  end

  test "a member cannot open another creators draft through any card view" do
    [ card_path(@draft), edit_card_path(@draft), card_draft_path(@draft) ].each do |path|
      get path
      assert_response :not_found
      assert_no_match @draft.title, response.body
      assert_no_match @draft.description.to_plain_text, response.body
    end

    get card_path(@draft), as: :json
    assert_response :not_found
  end

  test "a member cannot change another creators draft" do
    assert_no_changes -> { @draft.reload.attributes } do
      patch card_path(@draft), params: { card: { title: "Changed", description: "Changed body" } }, as: :json
    end

    assert_response :not_found
    assert_equal "Private draft description", @draft.reload.description.to_plain_text
  end

  test "a member cannot publish another creators draft" do
    assert_no_changes -> { @draft.reload.attributes } do
      assert_no_difference -> { @draft.events.count } do
        post card_publish_path(@draft), params: { column_id: columns(:writebook_triage).id }, as: :json
      end
    end

    assert_response :not_found
  end

  test "exact searches do not expose another creators draft in HTML or JSON" do
    get search_path(q: @draft.number)
    assert_response :success
    assert_no_match @draft.title, response.body
    assert_no_match @draft.description.to_plain_text, response.body
    assert_select "form[data-search-redirect]", count: 0

    get search_path(q: @draft.number), as: :json
    assert_response :success
    assert_not_includes response.parsed_body.pluck("id"), @draft.id
  end

  test "exact reference suggestions do not expose another creators draft" do
    get prompts_cards_path(filter: @draft.number)
    assert_response :success
    assert_no_match @draft.title, response.body
    assert_select "lexxy-prompt-item template[type=editor] a[href=?]", card_path(@draft), count: 0
  end

  [ :david, :kevin ].each do |user|
    test "#{user} can open search suggest update and publish the draft" do
      logout_and_sign_in_as user

      get card_draft_path(@draft)
      assert_response :success

      get card_path(@draft)
      assert_redirected_to card_draft_path(@draft)

      get search_path(q: @draft.number), as: :json
      assert_response :success
      assert_equal [ @draft.id ], response.parsed_body.pluck("id")

      get search_path(q: @draft.number)
      assert_response :success
      assert_select "form[data-search-redirect][action=?]", card_path(@draft), count: 1

      get prompts_cards_path(filter: @draft.number)
      assert_response :success
      assert_select "lexxy-prompt-item template[type=editor] a[href=?]", card_path(@draft), count: 1

      patch card_path(@draft), params: { card: { title: "Ready" } }, as: :json
      assert_response :success
      assert_equal "Ready", @draft.reload.title

      post card_publish_path(@draft), as: :json
      assert_response :created
      assert @draft.reload.published?
    end
  end

  test "an admin cannot open update or publish a draft without board access" do
    logout_and_sign_in_as :kevin
    boards(:writebook).update! all_access: false
    boards(:writebook).accesses.revoke_from users(:kevin)

    get card_draft_path(@draft)
    assert_response :not_found

    assert_no_changes -> { @draft.reload.attributes } do
      patch card_path(@draft), params: { card: { title: "Changed" } }, as: :json
      assert_response :not_found
      post card_publish_path(@draft), as: :json
      assert_response :not_found
    end
  end

  test "members can still read and collaboratively update published cards" do
    @draft.published!

    get card_path(@draft), as: :json
    assert_response :success
    assert_equal @draft.id, response.parsed_body["id"]

    patch card_path(@draft), params: { card: { title: "Collaborative edit" } }, as: :json
    assert_response :success
    assert_equal "Collaborative edit", @draft.reload.title
  end

  test "a member cannot republish another creators published card" do
    @draft.published!

    assert_no_changes -> { @draft.reload.attributes } do
      assert_no_difference -> { @draft.events.count } do
        post card_publish_path(@draft), as: :json
      end
    end

    assert_response :forbidden
  end
end
