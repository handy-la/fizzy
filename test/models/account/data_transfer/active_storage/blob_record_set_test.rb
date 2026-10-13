require "test_helper"

class Account::DataTransfer::ActiveStorage::BlobRecordSetTest < ActiveSupport::TestCase
  test "import generates fresh keys instead of using exported keys" do
    blob_id = ActiveRecord::Type::Uuid.generate
    exported_key = "original-exported-key-abc123"

    zip = build_zip_with_blob(id: blob_id, key: exported_key)
    Account::DataTransfer::ActiveStorage::BlobRecordSet.new(Current.account).import(from: zip)

    blob = ActiveStorage::Blob.find(blob_id)
    assert_not_equal exported_key, blob.key
    assert_equal 28, blob.key.length
  end

  test "import persists measured size and checksum without imported quota authority" do
    blob_id = ActiveRecord::Type::Uuid.generate

    zip = build_zip_with_blob(
      id: blob_id,
      key: "some-key",
      filename: "report.pdf",
      content_type: "application/pdf",
      file_content: "valid file content",
      metadata: { analyzed: true, width: 999, quota_upload: false }
    )
    Account::DataTransfer::ActiveStorage::BlobRecordSet.new(Current.account).import(from: zip)

    blob = ActiveStorage::Blob.find(blob_id)
    assert_equal "report.pdf", blob.filename.to_s
    assert_equal "application/pdf", blob.content_type
    assert_equal "valid file content".bytesize, blob.byte_size
    assert_equal Digest::MD5.base64digest("valid file content"), blob.checksum
    assert_equal({ "analyzed" => true, "width" => 999 }, blob.metadata)
  end

  test "import rejects negative and non integer sizes before upload" do
    [ -1, "1", 1.5, nil ].each do |size|
      blob_id = ActiveRecord::Type::Uuid.generate
      zip = build_zip_with_blob(id: blob_id, key: "invalid-size", byte_size: size)
      ActiveStorage::Blob.service.expects(:upload).never

      assert_raises(Account::DataTransfer::RecordSet::IntegrityError) do
        Account::DataTransfer::ActiveStorage::BlobRecordSet.new(Current.account).import(from: zip)
      end
      assert_not ActiveStorage::Blob.exists?(blob_id)
    end
  end

  test "check rejects a negative size before processing" do
    zip = build_zip_with_blob(id: ActiveRecord::Type::Uuid.generate, key: "negative", byte_size: -1)

    assert_raises(Account::DataTransfer::RecordSet::IntegrityError) do
      Account::DataTransfer::ActiveStorage::BlobRecordSet.new(Current.account).check(from: zip)
    end
  end

  test "import rejects sizes smaller or larger than the body and checksum mismatches" do
    [ { byte_size: 1 }, { byte_size: 100 }, { checksum: Digest::MD5.base64digest("different") } ].each do |override|
      blob_id = ActiveRecord::Type::Uuid.generate
      zip = build_zip_with_blob(id: blob_id, key: "mismatched", **override)

      assert_raises(Account::DataTransfer::RecordSet::IntegrityError) do
        Account::DataTransfer::ActiveStorage::BlobRecordSet.new(Current.account).import(from: zip)
      end
      assert_not ActiveStorage::Blob.exists?(blob_id)
    end
  end

  test "import preserves a referenced missing body without storage authority" do
    blob_id = ActiveRecord::Type::Uuid.generate
    zip = build_zip_with_blob(id: blob_id, key: "missing", include_file: false, referenced: true)
    Account::DataTransfer::ActiveStorage::BlobRecordSet.new(Current.account).import(from: zip)

    blob = ActiveStorage::Blob.find(blob_id)
    assert_equal 0, blob.byte_size
    assert_nil blob.checksum
    assert_not blob.service.exist?(blob.key)
  end

  test "import accepts an empty file" do
    blob_id = ActiveRecord::Type::Uuid.generate
    zip = build_zip_with_blob(id: blob_id, key: "empty", file_content: "")
    Account::DataTransfer::ActiveStorage::BlobRecordSet.new(Current.account).import(from: zip)

    assert_equal 0, ActiveStorage::Blob.find(blob_id).byte_size
    assert_equal Digest::MD5.base64digest(""), ActiveStorage::Blob.find(blob_id).checksum
  end

  test "database rejects a negative blob size" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("valid"), filename: "valid.txt")
    assert_raises(ActiveRecord::StatementInvalid) { blob.update_column(:byte_size, -1) }
  end

  [ false, true ].each do |serialized|
    test "import rebuilds portable metadata without quota authority from #{serialized ? "serialized JSON" : "JSON object"}" do
      blob_id = ActiveRecord::Type::Uuid.generate
      metadata = { "width" => 100, "height" => 200, "analyzed" => true,
        "quota_upload" => true, "quota_identity_id" => identities(:mike).id,
        "quota_expires_at" => 1.hour.from_now.iso8601, "quota_future" => "forged",
        "custom" => { "quota_upload" => true } }
      zip = build_zip_with_blob(id: blob_id, key: "forged-key", metadata: serialized ? metadata.to_json : metadata)

      Account::DataTransfer::ActiveStorage::BlobRecordSet.new(Current.account).import(from: zip)

      blob = ActiveStorage::Blob.find(blob_id)
      assert_equal({ "width" => 100, "height" => 200, "analyzed" => true }, blob.metadata)
      attachment = ActiveStorage::Attachment.create!(record: cards(:logo), name: "image", blob: blob)
      assert_no_difference "Storage::UploadReservation.count" do
        attachment.destroy!
      end
    end
  end

  private
    def build_zip_with_blob(id:, key:, filename: "test.txt", content_type: "text/plain", file_content: "hello world", byte_size: file_content.bytesize, checksum: Digest::MD5.base64digest(file_content), metadata: {}, include_file: true, referenced: false)
      tempfile = Tempfile.new([ "test_export", ".zip" ])
      tempfile.binmode

      writer = ZipFile::Writer.new(tempfile)
      writer.add_file("data/active_storage_blobs/#{id}.json", {
        id: id,
        account_id: ActiveRecord::Type::Uuid.generate,
        byte_size: byte_size,
        checksum: checksum,
        content_type: content_type,
        created_at: Time.current.iso8601,
        filename: filename,
        key: key,
        metadata: metadata
      }.to_json)
      if referenced
        writer.add_file("data/active_storage_attachments/missing.json", { blob_id: id }.to_json)
      end
      writer.add_file("storage/#{key}", file_content, compress: false) if include_file
      writer.close

      tempfile.rewind
      ZipFile::Reader.new(tempfile)
    end
end
