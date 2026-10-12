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

  test "import preserves blob metadata" do
    blob_id = ActiveRecord::Type::Uuid.generate

    zip = build_zip_with_blob(
      id: blob_id,
      key: "some-key",
      filename: "report.pdf",
      content_type: "application/pdf",
      byte_size: 12345,
      checksum: "abc123checksum"
    )
    Account::DataTransfer::ActiveStorage::BlobRecordSet.new(Current.account).import(from: zip)

    blob = ActiveStorage::Blob.find(blob_id)
    assert_equal "report.pdf", blob.filename.to_s
    assert_equal "application/pdf", blob.content_type
    assert_equal 12345, blob.byte_size
    assert_equal "abc123checksum", blob.checksum
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
    def build_zip_with_blob(id:, key:, filename: "test.txt", content_type: "text/plain", byte_size: 32, checksum: "", metadata: {})
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
      writer.add_file("storage/#{key}", "x" * byte_size, compress: false)
      writer.close

      tempfile.rewind
      ZipFile::Reader.new(tempfile)
    end
end
