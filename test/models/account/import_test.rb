require "test_helper"

class Account::ImportTest < ActiveSupport::TestCase
  include ZipTestHelper

  test "cleanup deletes completed imports older than 24 hours" do
    identity = identities(:david)
    old_completed = Account::Import.create!(account: Current.account, identity: identity, status: :completed, completed_at: 25.hours.ago)
    recent_completed = Account::Import.create!(account: Current.account, identity: identity, status: :completed, completed_at: 23.hours.ago)

    Account::Import.cleanup

    assert_not Account::Import.exists?(old_completed.id)
    assert Account::Import.exists?(recent_completed.id)
  end

  test "cleanup destroys accounts for failed imports older than 7 days" do
    identity = identities(:david)
    old_failed_account = Account.create!(name: "Old Failed Import")
    old_failed = Account::Import.create!(account: old_failed_account, identity: identity, status: :failed, created_at: 8.days.ago)
    recent_failed_account = Account.create!(name: "Recent Failed Import")
    recent_failed = Account::Import.create!(account: recent_failed_account, identity: identity, status: :failed, created_at: 6.days.ago)

    Account::Import.cleanup

    assert_not Account::Import.exists?(old_failed.id)
    assert_not Account.exists?(old_failed_account.id)
    assert Account::Import.exists?(recent_failed.id)
    assert Account.exists?(recent_failed_account.id)
  end

  test "export and import round-trip preserves account data" do
    source_account = accounts("37s")
    exporter = users(:david)
    identity = exporter.identity

    source_account_digest = account_digest(source_account)
    source_user_settings = user_settings_digest(source_account)

    export = Account::Export.create!(account: source_account, user: exporter)
    export.build

    assert export.completed?

    export_tempfile = Tempfile.new([ "export", ".zip" ])
    export.file.open { |f| FileUtils.cp(f.path, export_tempfile.path) }

    source_account.destroy!

    target_account = Account.create_with_owner(account: { name: "Import Test" }, owner: { identity: identity, name: exporter.name })
    import = Account::Import.create!(identity: identity, account: target_account)
    Current.set(account: target_account) do
      import.file.attach(io: File.open(export_tempfile.path), filename: "export.zip", content_type: "application/zip")
    end

    import.check
    assert_not import.failed?

    import.process
    assert import.completed?

    assert_equal source_account_digest, account_digest(target_account)
    assert_equal source_user_settings, user_settings_digest(target_account).slice(*source_user_settings.keys)
    assert_empty users_without_settings(target_account)
    assert_empty duplicate_user_settings(target_account)
  ensure
    export_tempfile&.close
    export_tempfile&.unlink
  end

  test "import creates settings for users whose export carried none" do
    source_account = accounts("37s")
    exporter = users(:david)
    identity = exporter.identity

    export = Account::Export.create!(account: source_account, user: exporter)
    export.build

    export_tempfile = Tempfile.new([ "export", ".zip" ])
    export.file.open { |f| FileUtils.cp(f.path, export_tempfile.path) }

    stripped_tempfile = zip_without(export_tempfile.path, "data/user_settings/*")

    source_account.destroy!

    target_account = Account.create_with_owner(account: { name: "Import Test" }, owner: { identity: identity, name: exporter.name })
    import = Account::Import.create!(identity: identity, account: target_account)
    Current.set(account: target_account) do
      import.file.attach(io: File.open(stripped_tempfile.path), filename: "export.zip", content_type: "application/zip")
    end

    import.check
    import.process

    assert import.completed?
    assert_operator User.where(account: target_account).where.not(role: :system).count, :>, 1
    assert_empty users_without_settings(target_account)
    assert_empty duplicate_user_settings(target_account)
    assert_empty User::Settings.where(account: target_account).joins(:user).where(user: { role: :system })
  ensure
    export_tempfile&.close
    export_tempfile&.unlink
    stripped_tempfile&.close
    stripped_tempfile&.unlink
  end

  test "import reconciles cards count so new cards get correct numbers" do
    source_account = accounts("37s")
    exporter = users(:david)
    identity = exporter.identity
    max_card_number = source_account.cards.maximum(:number)

    export = Account::Export.create!(account: source_account, user: exporter)
    export.build

    export_tempfile = Tempfile.new([ "export", ".zip" ])
    export.file.open { |f| FileUtils.cp(f.path, export_tempfile.path) }

    source_account.destroy!

    target_account = Account.create_with_owner(account: { name: "Import Test" }, owner: { identity: identity, name: exporter.name })
    import = Account::Import.create!(identity: identity, account: target_account)
    Current.set(account: target_account) do
      import.file.attach(io: File.open(export_tempfile.path), filename: "export.zip", content_type: "application/zip")
    end

    import.check
    import.process

    target_account.reload
    assert_operator target_account.cards_count, :>=, max_card_number
  ensure
    export_tempfile&.close
    export_tempfile&.unlink
  end

  test "check sets no failure_reason for unexpected errors" do
    import = Account::Import.create!(identity: identities(:david), account: Account.create!(name: "Import Test"))

    assert_raises(NoMethodError) { import.check }

    assert import.failed?
    assert_nil import.failure_reason
  end

  test "check sets failure_reason to invalid_export for non-Fizzy ZIP" do
    target_account = Account.create!(name: "Import Test")
    import = Account::Import.create!(identity: identities(:david), account: target_account)

    # Create a ZIP with no account.json
    tempfile = Tempfile.new([ "bad_export", ".zip" ])
    tempfile.binmode
    writer = ZipFile::Writer.new(tempfile)
    writer.add_file("data/dummy.json", '{"hello": "world"}')
    writer.close
    tempfile.rewind

    Current.set(account: target_account) do
      import.file.attach(io: tempfile, filename: "export.zip", content_type: "application/zip")
    end

    assert_raises(ZipFile::InvalidFileError) { import.check }

    assert import.failed?
    assert_equal "invalid_export", import.failure_reason
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "check sets failure_reason to invalid_export for non-ZIP file" do
    target_account = Account.create!(name: "Import Test")
    import = Account::Import.create!(identity: identities(:david), account: target_account)

    tempfile = Tempfile.new([ "not_a_zip", ".zip" ])
    tempfile.write("this is not a zip file at all")
    tempfile.rewind

    Current.set(account: target_account) do
      import.file.attach(io: tempfile, filename: "export.zip", content_type: "application/zip")
    end

    assert_raises(ZipFile::InvalidFileError) { import.check }

    assert import.failed?
    assert_equal "invalid_export", import.failure_reason
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "check sets failure_reason to invalid_export when a record entry inflates past the size limit" do
    source_account = accounts("37s")
    exporter = users(:david)
    identity = exporter.identity

    export = Account::Export.create!(account: source_account, user: exporter)
    export.build

    export_tempfile = Tempfile.new([ "export", ".zip" ])
    export.file.open { |f| FileUtils.cp(f.path, export_tempfile.path) }

    bomb_tempfile = with_oversized_tag(export_tempfile)

    source_account.destroy!

    target_account = Account.create_with_owner(account: { name: "Import Test" }, owner: { identity: identity, name: exporter.name })
    import = Account::Import.create!(identity: identity, account: target_account)
    Current.set(account: target_account) do
      import.file.attach(io: File.open(bomb_tempfile.path), filename: "export.zip", content_type: "application/zip")
    end

    # The directory limits (ZipFile::Limits) reject this entry's compression
    # ratio with a LimitExceededError before the reader's buffered cap is reached.
    assert_raises(ZipFile::LimitExceededError) { import.check }

    assert import.reload.failed_due_to_invalid_export?
  ensure
    export_tempfile&.close
    export_tempfile&.unlink
    bomb_tempfile&.close
    bomb_tempfile&.unlink
  end

  test "check sets failure_reason to conflict when records already exist" do
    source_account = accounts("37s")
    exporter = users(:david)
    identity = exporter.identity

    export = Account::Export.create!(account: source_account, user: exporter)
    export.build

    export_tempfile = Tempfile.new([ "export", ".zip" ])
    export.file.open { |f| FileUtils.cp(f.path, export_tempfile.path) }

    # Import without destroying the source, so records still exist
    target_account = Account.create_with_owner(account: { name: "Import Test" }, owner: { identity: identity, name: exporter.name })
    import = Account::Import.create!(identity: identity, account: target_account)
    Current.set(account: target_account) do
      import.file.attach(io: File.open(export_tempfile.path), filename: "export.zip", content_type: "application/zip")
    end

    assert_raises(Account::DataTransfer::RecordSet::ConflictError) { import.check }

    assert import.failed?
    assert_equal "conflict", import.failure_reason
  ensure
    export_tempfile&.close
    export_tempfile&.unlink
  end

  test "export and import round-trip preserves blobs and attachments" do
    source_account = accounts("37s")
    exporter = users(:david)
    identity = exporter.identity

    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("test image data"),
      filename: "logo.png",
      content_type: "image/png"
    )

    source_blob_count = ActiveStorage::Blob.where(account: source_account).count
    source_blob_keys = ActiveStorage::Blob.where(account: source_account).pluck(:key)

    assert_operator source_blob_count, :>, 0

    export = Account::Export.create!(account: source_account, user: exporter)
    export.build

    export_tempfile = Tempfile.new([ "export", ".zip" ])
    export.file.open { |f| FileUtils.cp(f.path, export_tempfile.path) }

    ActiveStorage::Blob.where(account: source_account).delete_all
    source_account.destroy!

    target_account = Account.create_with_owner(account: { name: "Import Test" }, owner: { identity: identity, name: exporter.name })
    import = Account::Import.create!(identity: identity, account: target_account)
    Current.set(account: target_account) do
      import.file.attach(io: File.open(export_tempfile.path), filename: "export.zip", content_type: "application/zip")
    end

    import.check
    assert_not import.failed?

    import.process
    assert import.completed?

    imported_blob = ActiveStorage::Blob.find_by(account: target_account, filename: "logo.png")
    assert_not_nil imported_blob
    assert_not_includes source_blob_keys, imported_blob.key
    assert_equal "test image data", imported_blob.download
  ensure
    export_tempfile&.close
    export_tempfile&.unlink
  end

  test "imported avatar is charged by reconciliation and released on purge with server reservations" do
    data = file_fixture("moon.jpg").binread
    source_account = accounts("37s")
    Current.set(account: source_account) do
      users(:kevin).avatar.attach(io: file_fixture("moon.jpg").open, filename: "moon.jpg", content_type: "image/jpeg")
    end
    users(:kevin).avatar.blob.update!(metadata: users(:kevin).avatar.blob.metadata.merge(
      "quota_upload" => true, "quota_identity_id" => identities(:david).id,
      "quota_expires_at" => 1.day.from_now.iso8601(6)))

    export = Account::Export.create!(account: source_account, user: users(:david))
    export.build
    data_blob_count = ActiveStorage::Blob.where(account: source_account).where.not(id: export.file.blob_id).count
    tempfile = Tempfile.new([ "export", ".zip" ])
    export.file.open { |f| FileUtils.cp(f.path, tempfile.path) }
    ActiveStorage::VariantRecord.where(blob: ActiveStorage::Blob.where(account: source_account)).delete_all
    ActiveStorage::Attachment.where(account: source_account).delete_all
    ActiveStorage::Blob.where(account: source_account).delete_all
    source_account.destroy!

    import = import_from(tempfile.path)
    import.check
    assert_difference "Storage::UploadReservation.count", data_blob_count do
      import.process
    end
    assert import.completed?

    account = import.account
    avatar = ActiveStorage::Attachment.find_by!(account: account, record_type: "User", name: "avatar")
    assert_equal data.bytesize, avatar.blob.byte_size
    assert_not avatar.blob.metadata.key?("quota_identity_id")
    assert_not avatar.blob.metadata.key?("quota_expires_at")
    charged = account.bytes_used_exact
    assert_equal account.send(:calculate_real_storage_bytes), charged
    assert_operator charged, :>=, data.bytesize
    assert account.reconcile_storage
    assert_equal charged, account.reload.bytes_used_exact

    assert_no_difference "Storage::UploadReservation.count" do
      User.find(avatar.record_id).avatar.purge
    end
    assert_equal charged, account.reload.bytes_used_exact
    assert account.reconcile_storage
    assert_equal charged, account.reload.bytes_used_exact
    travel 3.hours do
      assert_difference "Storage::UploadReservation.count", -1 do
        Storage::UploadReservation.cleanup
      end
      assert_equal charged - data.bytesize, account.reload.bytes_used_exact
      assert account.reconcile_storage
      assert_equal charged - data.bytesize, account.reload.bytes_used_exact
    end
  ensure
    tempfile&.close!
  end

  test "check reserves storage space for the validated uncompressed size" do
    import = import_with_attached(compressible_zip)
    import.stubs(:available_storage_space).returns(import.file.blob.byte_size * Account::Import::REQUIRED_STORAGE_SPACE_FACTOR)

    error = assert_raises(Account::Import::InsufficientStorageSpaceError) { import.check }
    assert_match(/import needs ~1 MB free, found/, error.message)
    assert import.reload.failed_due_to_insufficient_storage_space?
  end

  test "check rejects when free storage space cannot be determined" do
    import = import_with_attached(compressible_zip)
    import.stubs(:available_storage_space).returns(nil)

    assert_raises(Account::Import::InsufficientStorageSpaceError) { import.check }
    assert import.reload.failed_due_to_insufficient_storage_space?
  end

  test "process fails fast with a clear reason when free storage space is insufficient" do
    import = import_with_attached(compressible_zip)
    import.stubs(:available_storage_space).returns(import.file.blob.byte_size * Account::Import::REQUIRED_STORAGE_SPACE_FACTOR)

    assert_raises(Account::Import::InsufficientStorageSpaceError) { import.process }
    assert import.reload.failed_due_to_insufficient_storage_space?
  end

  test "resumed process skips the storage space preflight" do
    import = import_with_attached_zip
    import.stubs(:available_storage_space).returns(import.file.blob.byte_size)

    assert_raises(ZipFile::InvalidFileError) { import.process(start: [ "Board", nil ]) }
    assert import.reload.failed_due_to_invalid_export?
  end

  test "available_storage_space is indeterminate when df output is unparseable" do
    import = import_with_attached_zip
    Account::Import.stubs(:`).returns("Filesystem 1024-blocks Used Available Capacity Mounted on\n")

    assert_nil import.send(:available_storage_space, "/tmp")
  end

  test "available_storage_space parses df output whose filesystem name contains spaces" do
    import = import_with_attached_zip
    Account::Import.stubs(:`).returns(<<~DF)
      Filesystem 1024-blocks Used Available Capacity Mounted on
      map auto home 1000000 250000 750000 25% /System/Volumes/Data/home
    DF

    assert_equal 750_000 * 1024, import.send(:available_storage_space, "/tmp")
  end

  test "check rejects a small ZIP with an entry of extreme expansion before extracting it" do
    export = export_with_blobs
    bomb_entry = nil
    bomb = rewrite_zip(export.path) do |name, content, storage_entries|
      if name == storage_entries.last
        bomb_entry = name
        [ "\0" * 8.megabytes, true ]
      else
        [ content, !name.start_with?("storage/") ]
      end
    end
    import = import_from(bomb.path)

    assert_operator File.size(bomb.path), :<, 1.megabyte
    ZipKit::FileReader::ZipEntry.any_instance.expects(:extractor_from).never

    error = assert_raises(ZipFile::InvalidFileError) { import.check }
    assert_match(/#{Regexp.escape(bomb_entry)} has a compression ratio above 50:1/, error.message)
    assert import.reload.failed_due_to_invalid_export?
    assert_empty Card.where(account: import.account)
  ensure
    export&.close!
    bomb&.close!
  end

  test "process stops a stored file that expands beyond its declared size and discards the partial import" do
    export = export_with_blobs
    forged_entry = nil
    File.open(export.path, "rb") { |file| forged_entry = ZipFile::Reader.new(file).glob("storage/*").last }
    forged_key = forged_entry.delete_prefix("storage/")
    tampered = rewrite_zip(export.path) do |name, content, _|
      if name.start_with?("data/active_storage_blobs/")
        data = JSON.parse(content)
        data["byte_size"] = 1 if data["key"] == forged_key
        content = data.to_json
      end
      [ content, false ]
    end
    declare_uncompressed_size(tampered.path, forged_entry, 1)
    import = import_from(tampered.path)
    uploaded_keys = []
    subscriber = ActiveSupport::Notifications.subscribe("service_upload.active_storage") { |*, payload| uploaded_keys << payload[:key] }

    import.check
    error = assert_raises(ZipFile::InvalidFileError) { import.process }

    assert_match(/#{Regexp.escape(forged_entry)} expands past the 1 bytes it declares/, error.message)
    assert import.reload.failed_due_to_invalid_export?
    assert_operator uploaded_keys.size, :>, 0
    uploaded_keys.each { |key| assert_not ActiveStorage::Blob.service.exist?(key), "partial blob file #{key} was left on storage" }
    assert_empty ActiveStorage::Blob.where(account: import.account)
    assert_empty Card.where(account: import.account)
    assert_empty Board.where(account: import.account)
    assert_empty User.where(account: import.account)
    assert_empty ActiveStorage::Attachment.where(account: import.account).where.not(record_type: "Account::Import")
    assert_not import.file.attached?
  ensure
    tampered&.close!
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    export&.close!
  end

  test "failed object deletion preserves the ZIP and quota until cleanup succeeds" do
    tempfile = compressible_zip
    import = import_with_attached(tempfile)
    admission = Account::Import::Admission.claim(identity: import.identity, import: import)
    admission.reserve(account: import.account, bytes: 512.kilobytes + import.file.blob.byte_size)
    blob = import.file.blob
    blob.service.stubs(:delete).raises(IOError, "storage unavailable")

    assert_raises(IOError) { import.mark_as_failed(:invalid_export) }
    assert import.reload.failed?
    assert import.file.attached?
    assert ActiveStorage::Blob.exists?(blob.id)
    assert_equal 512.kilobytes + blob.byte_size, import.account.bytes_used_exact
    assert_nil admission.reload.finished_at

    blob.service.unstub(:delete)
    Account::Import.cleanup
    assert_not blob.service.exist?(blob.key)
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not import.reload.file.attached?
    assert_equal 0, import.account.bytes_used_exact
    assert admission.reload.finished_at
  ensure
    tempfile&.close!
  end

  # Authoring record: docs/test-audits/handy-954.md.
  test "cleanup purges the next failed import when one object deletion fails" do
    zips = [ compressible_zip, compressible_zip ]
    first, second = zips.map { |zip| import_with_attached(zip) }.sort_by(&:id)
    second.update!(identity: identities(:kevin))
    first_admission, second_admission = [ first, second ].map do |import|
      Account::Import::Admission.claim(identity: import.identity, import: import).tap do |admission|
        admission.reserve(account: import.account, bytes: import.file.blob.byte_size)
      end
    end
    first.update_columns(status: :failed, created_at: 8.days.ago)
    second.update_columns(status: :failed)
    stale = Account::Import::Admission.create!(identity: identities(:jz), finished_at: 25.hours.ago)
    first_blob, second_blob = first.file.blob, second.file.blob
    service = first_blob.service
    original_delete = service.method(:delete)
    service.define_singleton_method(:delete) do |key|
      raise IOError, "storage unavailable" if key == first_blob.key
      original_delete.call(key)
    end

    assert_nothing_raised { Account::Import.cleanup }

    assert Account::Import.exists?(first.id), "an expired import whose purge failed must stay for the next sweep"
    assert first.reload.file.attached?
    assert ActiveStorage::Blob.exists?(first_blob.id)
    assert_equal first_blob.byte_size, first.account.bytes_used_exact
    assert_nil first_admission.reload.finished_at
    assert_not second.reload.file.attached?
    assert_not service.exist?(second_blob.key)
    assert_not ActiveStorage::Blob.exists?(second_blob.id)
    assert_equal 0, second.account.bytes_used_exact
    assert second_admission.reload.finished_at
    assert_not Account::Import::Admission.exists?(stale.id)
  ensure
    service&.singleton_class&.remove_method(:delete) if service&.singleton_class&.method_defined?(:delete, false)
    zips&.each(&:close!)
  end

  test "completed import keeps unattached blobs charged and releases ZIP reservation" do
    export = export_with_blobs
    import = import_from(export.path)
    import.check
    reserved = import.admission.reserved_bytes
    assert_equal reserved, import.account.bytes_used_exact
    import.process

    assert import.reload.completed?
    assert_not import.file.attached?
    assert_equal 0, import.admission.reload.reserved_bytes
    assert import.admission.finished_at
    assert_equal 12, import.account.bytes_used_exact
    assert_equal 2, Storage::UploadReservation.where(account: import.account).count
    blobs = ActiveStorage::Blob.where(account: import.account).to_a
    assert blobs.all? { |blob| blob.metadata.keys.none? { |key| key.start_with?("quota_") } }
    Storage::UploadReservation.cleanup
    assert blobs.all? { |blob| blob.service.exist?(blob.key) }
  ensure
    export&.close!
  end

  test "blob metadata cannot exceed declared storage entry bytes" do
    export = export_with_blobs
    tampered = rewrite_zip(export.path) do |name, content, _|
      if name.start_with?("data/active_storage_blobs/")
        data = JSON.parse(content)
        data["byte_size"] = 1.gigabyte
        content = data.to_json
      end
      [ content, false ]
    end
    import = import_from(tampered.path)
    error = assert_raises(Account::DataTransfer::RecordSet::IntegrityError) { import.check }
    assert_match(/Blob size does not match/, error.message)
    assert_not import.file.attached?
    assert_empty ActiveStorage::Blob.where(account: import.account)
    assert_equal 0, import.account.bytes_used_exact
  ensure
    tampered&.close!
    export&.close!
  end

  test "missing storage file in a legitimate export preserves its blob and attachment without charging bytes" do
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("pending"), filename: "pending.txt",
      content_type: "text/plain", metadata: { "width" => 90 })
    cards(:logo).image.attach(blob)
    blob.delete
    export = Account::Export.create!(account: Current.account, user: users(:david))
    export.build
    tempfile = Tempfile.new([ "pending-export", ".zip" ])
    export.file.open { |file| FileUtils.cp(file.path, tempfile.path) }
    ActiveStorage::Blob.where(account: Current.account).delete_all
    Current.account.destroy!

    import = import_from(tempfile.path)
    import.check
    import.process
    assert import.reload.completed?
    imported_blob = ActiveStorage::Blob.find_by!(account: import.account, filename: "pending.txt")
    assert_equal 0, imported_blob.byte_size
    assert_nil imported_blob.checksum
    assert_equal 90, imported_blob.metadata["width"]
    assert_equal 1, imported_blob.attachments.count
    assert_not imported_blob.service.exist?(imported_blob.key)
    assert_equal 0, import.account.bytes_used_exact
  ensure
    tempfile&.close!
  end

  test "imported avatar uses a server reservation through attachment reconciliation and deletion" do
    data = file_fixture("avatar.png").binread
    source_blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new(data), filename: "imported-avatar.png",
      content_type: "image/png")
    users(:david).avatar.attach(source_blob)
    export = Account::Export.create!(account: Current.account, user: users(:david))
    export.build
    exported_bytes = ActiveStorage::Blob.where(account: Current.account).where.not(id: export.file.blob_id).sum(:byte_size)
    tempfile = Tempfile.new([ "avatar-export", ".zip" ])
    export.file.open { |file| FileUtils.cp(file.path, tempfile.path) }
    ActiveStorage::VariantRecord.where(blob_id: ActiveStorage::Blob.where(account: Current.account).select(:id)).delete_all
    ActiveStorage::Attachment.where(account: Current.account).delete_all
    ActiveStorage::Blob.where(account: Current.account).delete_all
    Current.account.destroy!

    import = import_from(tempfile.path)
    import.check
    import.process
    blob = ActiveStorage::Blob.find_by!(account: import.account, filename: "imported-avatar.png")
    assert blob.metadata.keys.none? { |key| key.start_with?("quota_") }
    reservation = Storage::UploadReservation.find_by!(blob: blob)
    assert_equal import.identity, reservation.identity
    assert_equal exported_bytes, import.account.bytes_used_exact
    assert_not Storage::UploadReservation.pending.exists?(id: reservation.id)
    assert import.account.reconcile_storage
    assert_equal exported_bytes, import.account.bytes_used_exact

    blob.attachments.first.destroy!
    assert_equal exported_bytes, import.account.bytes_used_exact
    assert Storage::UploadReservation.pending.exists?(id: reservation.id)
    blob.service.stubs(:delete).raises(IOError)
    assert_raises(IOError) { reservation.purge }
    assert ActiveStorage::Blob.exists?(blob.id)
    assert_equal exported_bytes, import.account.bytes_used_exact
    blob.service.unstub(:delete)
    reservation.purge
    assert_not blob.service.exist?(blob.key)
    assert_equal exported_bytes - data.bytesize, import.account.bytes_used_exact
  ensure
    tempfile&.close!
  end

  private
    def with_oversized_tag(export_tempfile)
      bomb = Tempfile.new([ "oversized_export", ".zip" ])
      bomb.binmode

      File.open(export_tempfile.path, "rb") do |file|
        reader = ZipFile::Reader.new(file)
        writer = ZipFile::Writer.new(bomb)

        target = reader.glob("data/tags/*.json").first
        tag = JSON.parse(reader.read(target))

        reader.glob("**/*").reject { |name| name.end_with?("/") || name == target }.each do |entry|
          writer.add_file(entry, reader.read(entry))
        end

        writer.add_file target, tag.merge("title" => "a" * (ZipFile::Reader::MAX_BUFFERED_ENTRY_SIZE + 1)).to_json
        writer.close
      end

      bomb.rewind
      bomb
    end

    def import_with_attached_zip
      account = Account.create!(name: "Disk Check")
      import = Account::Import.create!(account: account, identity: identities(:david))
      Current.set(account: account) do
        import.file.attach(io: StringIO.new("not actually a zip"), filename: "export.zip", content_type: "application/zip")
      end
      import
    end

    def import_with_attached(tempfile)
      account = Account.create!(name: "Disk Check")
      import = Account::Import.create!(account: account, identity: identities(:david))
      Current.set(account: account) do
        import.file.attach(io: File.open(tempfile.path), filename: "export.zip", content_type: "application/zip")
      end
      import
    end

    # Under the ratio exemption: 512 KB of spaces compress to a few hundred bytes.
    def compressible_zip
      tempfile = Tempfile.new([ "compressible", ".zip" ])
      tempfile.binmode
      writer = ZipFile::Writer.new(tempfile)
      writer.add_file("data/account.json", "{}")
      writer.add_file("data/padding.json", " " * 512.kilobytes)
      writer.close
      tempfile.rewind
      tempfile
    end

    def export_with_blobs
      source_account = accounts("37s")
      2.times do |index|
        ActiveStorage::Blob.create_and_upload!(io: StringIO.new("blob #{index}"), filename: "file#{index}.txt", content_type: "text/plain")
      end

      export = Account::Export.create!(account: source_account, user: users(:david))
      export.build

      tempfile = Tempfile.new([ "export", ".zip" ])
      export.file.open { |f| FileUtils.cp(f.path, tempfile.path) }

      ActiveStorage::Blob.where(account: source_account).delete_all
      source_account.destroy!
      tempfile
    end

    def import_from(path)
      identity = users(:david).identity
      account = Account.create_with_owner(account: { name: "Import Test" }, owner: { identity: identity, name: "David" })
      import = Account::Import.create!(identity: identity, account: account)
      Current.set(account: account) do
        import.file.attach(io: File.open(path), filename: "export.zip", content_type: "application/zip")
      end
      import
    end

    def rewrite_zip(path)
      tempfile = Tempfile.new([ "rewritten_export", ".zip" ])
      tempfile.binmode
      writer = ZipFile::Writer.new(tempfile)

      File.open(path, "rb") do |file|
        reader = ZipFile::Reader.new(file)
        storage_entries = reader.glob("storage/*")

        reader.glob("*").each do |entry|
          next if entry.end_with?("/")

          content, compress = yield(entry, reader.read(entry), storage_entries)
          writer.add_file(entry, content, compress: compress)
        end
      end

      writer.close
      tempfile.rewind
      tempfile
    end

    def account_digest(account)
      {
        name: account.name,
        board_count: Board.where(account: account).count,
        column_count: Column.where(account: account).count,
        column_colors: Column.where(account: account).order(:id).pluck(:color),
        card_count: Card.where(account: account).count,
        comment_count: Comment.where(account: account).count,
        tag_count: Tag.where(account: account).count,
        user_ids: User.where(account: account).where.not(role: :system).order(:id).pluck(:id)
      }
    end

    def user_settings_digest(account)
      User::Settings.where(account: account).pluck(:user_id, :bundle_email_frequency).to_h
    end

    def users_without_settings(account)
      User.where(account: account).where.not(role: :system).where.missing(:settings)
    end

    def duplicate_user_settings(account)
      User::Settings.where(account: account).group(:user_id).having("COUNT(*) > 1").count
    end

    def zip_without(path, pattern)
      tempfile = Tempfile.new([ "stripped_export", ".zip" ])
      tempfile.binmode
      writer = ZipFile::Writer.new(tempfile)

      File.open(path, "rb") do |file|
        reader = ZipFile::Reader.new(file)

        reader.glob("*").each do |entry|
          next if entry.end_with?("/")
          next if File.fnmatch(pattern, entry)

          writer.add_file(entry, reader.read(entry))
        end
      end

      writer.close
      tempfile.rewind
      tempfile
    end
end
