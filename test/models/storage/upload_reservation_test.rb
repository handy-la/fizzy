require "test_helper"

class Storage::UploadReservationTest < ActiveSupport::TestCase
  setup do
    Current.session = sessions(:david)
    @account = accounts("37s")
    @identity = identities(:david)
  end

  test "attachment transfers reserved bytes to the ledger without doubling" do
    blob = reserve
    assert_equal 5, @account.bytes_used_exact
    blob.upload(StringIO.new("hello"))
    cards(:logo).image.attach(blob)

    assert_not Storage::UploadReservation.exists?(blob: blob)
    assert_equal 5, @account.reload.bytes_used_exact
    assert_equal 5, boards(:writebook).bytes_used_exact
    @account.materialize_storage
    assert_equal 5, @account.reload.bytes_used
  end

  test "untracked avatar remains charged after attachment and reconciliation" do
    data = file_fixture("moon.jpg").binread
    blob = reserve(data: data, content_type: "image/jpeg")
    blob.upload(StringIO.new(data))
    users(:david).avatar.attach(blob)

    assert users(:david).avatar.attached?
    assert_not Storage::UploadReservation.exists?(blob: blob)
    assert_equal data.bytesize, @account.bytes_used_exact
    assert @account.reconcile_storage
    assert_equal data.bytesize, @account.bytes_used_exact
    users(:david).avatar.purge
    assert_equal data.bytesize, @account.bytes_used_exact
    travel 3.hours do
      Storage::UploadReservation.cleanup
      assert_equal 0, @account.bytes_used_exact
    end
  end

  test "rolling back attachment restores reservation and removes ledger charge" do
    blob = reserve
    blob.upload(StringIO.new("hello"))
    ApplicationRecord.transaction do
      cards(:logo).image.attach(blob)
      raise ActiveRecord::Rollback
    end

    assert Storage::UploadReservation.exists?(blob: blob)
    assert_equal 5, @account.reload.bytes_used_exact
    assert_not blob.attachments.exists?
  end

  test "cleanup deletes expired objects and reservations but keeps live uploads" do
    expired = reserve
    expired.upload(StringIO.new("hello"))
    Storage::UploadReservation.find_by!(blob: expired).update!(expires_at: 2.hours.ago)
    live = reserve
    live.upload(StringIO.new("hello"))

    Storage::CleanupUploadsJob.perform_now

    assert_not ActiveStorage::Blob.exists?(expired.id)
    assert_not expired.service.exist?(expired.key)
    assert_not Storage::UploadReservation.exists?(blob_id: expired.id)
    assert ActiveStorage::Blob.exists?(live.id)
    assert live.service.exist?(live.key)
    assert_equal 5, @account.bytes_used_exact
  end

  test "cleanup retains charge and key on storage failure and retries" do
    blob = reserve
    blob.upload(StringIO.new("hello"))
    reservation = Storage::UploadReservation.find_by!(blob: blob)
    reservation.update!(expires_at: 2.hours.ago)
    blob.service.stubs(:delete).raises(IOError)

    assert_raises(IOError) { Storage::UploadReservation.cleanup }
    assert ActiveStorage::Blob.exists?(blob.id)
    assert Storage::UploadReservation.exists?(reservation.id)
    assert_equal 5, @account.bytes_used_exact

    blob.service.unstub(:delete)
    Storage::UploadReservation.cleanup
    assert_not blob.service.exist?(blob.key)
    assert_equal 0, @account.bytes_used_exact
  end

  test "upload can attach after its URL expires while cleanup has not purged it" do
    blob = reserve
    blob.upload(StringIO.new("hello"))
    Storage::UploadReservation.find_by!(blob: blob).update!(expires_at: 1.minute.ago)

    cards(:logo).image.attach(blob)
    assert blob.attachments.exists?
    assert_not Storage::UploadReservation.exists?(blob: blob)
    Storage::UploadReservation.cleanup
    assert ActiveStorage::Blob.exists?(blob.id)
    assert_equal 5, @account.bytes_used_exact
  end

  test "URL generation failure leaves no blob or reservation" do
    assert_no_difference [ "ActiveStorage::Blob.count", "Storage::UploadReservation.count" ] do
      assert_raises(IOError) do
        reserve { raise IOError }
      end
    end
    assert_equal 0, @account.bytes_used_exact
  end

  test "identity limit applies across accounts" do
    20.times { reserve }
    other = accounts(:initech)
    assert_raises(Storage::UploadReservation::Rejected) do
      reserve(account: other)
    end
    assert_equal 100, @account.bytes_used_exact
    assert_equal 0, other.bytes_used_exact
  end

  test "account pending limit applies across identities" do
    100.times do
      blob = ActiveStorage::Blob.create_before_direct_upload!(filename: "hello.txt", byte_size: 1,
        checksum: Digest::MD5.base64digest("h"))
      Storage::UploadReservation.create!(account: @account, identity: identities(:jason), blob: blob,
        byte_size: 1, expires_at: 1.hour.from_now)
    end
    error = assert_raises(Storage::UploadReservation::Rejected) { reserve }
    assert_equal :too_many_requests, error.status
    assert_equal 100, @account.bytes_used_exact
  end

  test "cleanup also purges legacy abandoned blobs and preserves attached blobs" do
    old = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("hello"), filename: "old.txt")
    old.update_column(:created_at, 31.days.ago)
    attached = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("hello"), filename: "attached.txt")
    attached.update_column(:created_at, 31.days.ago)
    cards(:logo).image.attach(attached)

    Storage::UploadReservation.cleanup

    assert_not ActiveStorage::Blob.exists?(old.id)
    assert_not old.service.exist?(old.key)
    assert ActiveStorage::Blob.exists?(attached.id)
    assert attached.service.exist?(attached.key)
  end

  test "detaching cannot free quota while the signed upload URL can recreate the object" do
    blob = reserve
    blob.upload(StringIO.new("hello"))
    cards(:logo).image.attach(blob)
    cards(:logo).image.purge

    assert blob.service.exist?(blob.key)
    assert ActiveStorage::Blob.exists?(blob.id)
    assert Storage::UploadReservation.exists?(blob: blob)
    assert_equal 5, @account.reload.bytes_used_exact
    assert @account.reconcile_storage
    assert_equal 5, @account.bytes_used_exact

    travel 3.hours do
      Storage::UploadReservation.cleanup
      assert_not blob.service.exist?(blob.key)
      assert_equal 0, @account.bytes_used_exact
    end
  end

  test "configured account limit is enforced instead of the self hosted default" do
    @account.stubs(:storage_limit).returns(5)
    reserve
    error = assert_raises(Storage::UploadReservation::Rejected) { reserve }
    assert_equal :unprocessable_entity, error.status
    assert_equal 5, @account.bytes_used_exact
  end

  test "uploaded draft remains usable after a long pause" do
    blob = reserve
    blob.upload(StringIO.new("hello"))
    html = ActionText::Attachment.from_attachable(blob).to_html

    travel 3.days do
      Storage::UploadReservation.cleanup
      assert ActiveStorage::Blob.exists?(blob.id)
      assert_equal 5, @account.bytes_used_exact
      cards(:logo).update!(description: "<p>Draft</p>#{html}")
      assert cards(:logo).description.embeds.attached?
      assert_not Storage::UploadReservation.exists?(blob: blob)
      assert_equal 5, @account.reload.bytes_used_exact
    end
  end

  test "legacy uploaded draft is not deleted after a weekend" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("hello"), filename: "draft.txt")
    blob.update_column(:created_at, 3.days.ago)
    Storage::UploadReservation.cleanup
    assert ActiveStorage::Blob.exists?(blob.id)
    assert blob.service.exist?(blob.key)
  end

  test "detaching imported upload metadata does not require the original identity" do
    blob = reserve
    blob.upload(StringIO.new("hello"))
    cards(:logo).image.attach(blob)
    absent_id = Identity.type_for_attribute("id").cast(SecureRandom.uuid)
    assert_not Identity.exists?(absent_id)
    blob.update!(metadata: blob.metadata.merge("quota_identity_id" => absent_id))

    cards(:logo).image.purge
    assert_not blob.attachments.exists?
    assert_equal 5, @account.reload.bytes_used_exact
  end

  test "failed upload releases its reservation after the URL and grace expire" do
    blob = reserve
    travel 3.hours do
      Storage::UploadReservation.cleanup
      assert_not ActiveStorage::Blob.exists?(blob.id)
      assert_not Storage::UploadReservation.exists?(blob: blob)
      assert_equal 0, @account.bytes_used_exact
    end
  end

  test "uploaded but abandoned draft expires after thirty days" do
    blob = reserve
    blob.upload(StringIO.new("hello"))
    travel 31.days do
      Storage::UploadReservation.cleanup
      assert_not ActiveStorage::Blob.exists?(blob.id)
      assert_not blob.service.exist?(blob.key)
      assert_not Storage::UploadReservation.exists?(blob: blob)
      assert_equal 0, @account.bytes_used_exact
    end
  end

  private
    def reserve(account: @account, data: "hello", content_type: "text/plain", &block)
      Current.with_account(account) do
        Storage::UploadReservation.reserve(account: account, identity: @identity,
          attributes: { filename: "hello.txt", byte_size: data.bytesize, checksum: Digest::MD5.base64digest(data), content_type: content_type }) do |blob|
          block ? block.call(blob) : blob
        end
      end
    end
end
