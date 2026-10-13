require "test_helper"

# Handy #968: a representation that fails for ever must not reach the shared processor on every GET,
# and one account must not hold every processing slot. Authoring answers and RED evidence:
# docs/test-audits/handy-968.md.
class ActiveStorageRepresentationAdmissionTest < ActionDispatch::IntegrationTest
  class PermanentFailure < StandardError; end
  class TransientFailure < StandardError; end

  setup do
    # The test environment uses :null_store, which remembers nothing; production uses Solid Cache.
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
    @permanent_errors = ActiveStorage::RepresentationAdmission.permanent_errors
    ActiveStorage::RepresentationAdmission.permanent_errors = [ PermanentFailure ]

    @blob = attach_blob_to_card(cards(:logo), sessions(:david))
  end

  teardown do
    ActiveStorage::RepresentationAdmission.permanent_errors = @permanent_errors
  end

  test "a permanent failure runs the processor once and then answers 422" do
    transforms = count_transforms raising: PermanentFailure

    sign_in_as :david
    path = rails_representation_path(@blob.representation(resize_to_limit: [ 100, 100 ]))

    assert_raises(PermanentFailure) { get path }
    get path
    assert_response :unprocessable_entity
    get rails_storage_proxy_path(@blob.representation(resize_to_limit: [ 100, 100 ]))
    assert_response :unprocessable_entity

    assert_equal 1, transforms.size
  end

  test "another variation is not blocked by an earlier verdict" do
    transforms = count_transforms raising: PermanentFailure

    sign_in_as :david
    assert_raises(PermanentFailure) { get rails_representation_path(@blob.representation(resize_to_limit: [ 100, 100 ])) }
    assert_raises(PermanentFailure) { get rails_representation_path(@blob.representation(resize_to_limit: [ 200, 200 ])) }

    assert_equal 2, transforms.size
  end

  test "another processor version is not blocked by an earlier verdict" do
    transforms = count_transforms raising: PermanentFailure

    sign_in_as :david
    path = rails_representation_path(@blob.representation(resize_to_limit: [ 100, 100 ]))
    assert_raises(PermanentFailure) { get path }

    ActiveStorage::RepresentationAdmission.stubs(:processor_version).returns("upgraded")
    assert_raises(PermanentFailure) { get path }

    assert_equal 2, transforms.size
  end

  test "a transient failure is not remembered as permanent" do
    transforms = count_transforms raising: TransientFailure

    sign_in_as :david
    path = rails_representation_path(@blob.representation(resize_to_limit: [ 100, 100 ]))
    assert_raises(TransientFailure) { get path }
    assert_raises(TransientFailure) { get path }

    assert_equal 2, transforms.size
  end

  test "a saturated account is refused while another account is still served" do
    other_blob = attach_blob_to_card(cards(:radio), sessions(:mike))
    held = Array.new(ActiveStorage::RepresentationAdmission::CONCURRENCY_PER_ACCOUNT) { ActiveStorage::RepresentationAdmission.acquire_slot(@blob.account_id) }
    assert held.all?

    sign_in_as :david
    get rails_representation_path(@blob.representation(resize_to_limit: [ 100, 100 ]))
    assert_response :too_many_requests

    logout_and_sign_in_as :mike
    get rails_representation_path(other_blob.representation(resize_to_limit: [ 100, 100 ]), script_name: "/#{accounts(:initech).external_account_id}")
    assert_response :redirect
  ensure
    held&.each { |slot| slot&.release }
  end

  test "a slot is released after processing, also when it fails" do
    sign_in_as :david
    ActiveStorage::RepresentationAdmission::CONCURRENCY_PER_ACCOUNT.succ.times do |size|
      get rails_representation_path(@blob.representation(resize_to_limit: [ 10 + size, 10 + size ]))
      assert_response :redirect
    end

    count_transforms raising: TransientFailure
    ActiveStorage::RepresentationAdmission::CONCURRENCY_PER_ACCOUNT.succ.times do |size|
      assert_raises(TransientFailure) { get rails_representation_path(@blob.representation(resize_to_limit: [ 50 + size, 50 + size ])) }
    end
  end

  test "one identity is limited in how many new representations it asks for" do
    sign_in_as :david
    limit = ActiveStorage::RepresentationAdmission::PROCESSINGS_PER_MINUTE

    limit.times do |size|
      get rails_representation_path(@blob.representation(resize_to_limit: [ 10 + size, 10 + size ]))
      assert_response :redirect
    end

    get rails_representation_path(@blob.representation(resize_to_limit: [ 500, 500 ]))
    assert_response :too_many_requests

    get rails_representation_path(@blob.representation(resize_to_limit: [ 10, 10 ]))
    assert_response :redirect, "a representation that is already processed costs nothing"

    travel 1.minute
    get rails_representation_path(@blob.representation(resize_to_limit: [ 500, 500 ]))
    assert_response :redirect
  end

  private
    def count_transforms(raising:)
      [].tap do |transforms|
        ActiveStorage::Variation.any_instance.stubs(:transform).with { |*| transforms << true }.raises(raising)
      end
    end

    def attach_blob_to_card(card, session)
      Current.with(account: card.account, session: session) do
        card.image.attach! io: file_fixture("moon.jpg").open, filename: "test.jpg", content_type: "image/jpeg"
        card.image.blob
      end
    end
end
