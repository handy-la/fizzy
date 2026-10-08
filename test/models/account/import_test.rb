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

    assert_raises(Account::DataTransfer::RecordSet::IntegrityError) { import.check }

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

  test "check reserves storage space for the validated uncompressed size" do
    import = import_with_attached(compressible_zip)
    import.stubs(:available_storage_space).returns(import.file.blob.byte_size * Account::Import::REQUIRED_STORAGE_SPACE_FACTOR)

    error = assert_raises(Account::Import::InsufficientStorageSpaceError) { import.check }
    assert_match(/import needs ~1 MB free, found/, error.message)
    assert import.reload.failed_due_to_insufficient_storage_space?
  end

  test "check proceeds when free storage space cannot be determined" do
    import = import_with_attached(compressible_zip)
    import.stubs(:available_storage_space).returns(nil)

    assert_raises(Account::DataTransfer::RecordSet::IntegrityError) { import.check }
    assert import.reload.failed_due_to_invalid_export?
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
    import.stubs(:`).returns("Filesystem 1024-blocks Used Available Capacity Mounted on\n")

    assert_nil import.send(:available_storage_space, "/tmp")
  end

  test "available_storage_space parses df output whose filesystem name contains spaces" do
    import = import_with_attached_zip
    import.stubs(:`).returns(<<~DF)
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
    assert_match(/#{Regexp.escape(bomb_entry)} has a compression ratio above 100:1/, error.message)
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
    declare_uncompressed_size(export.path, forged_entry, 1)
    import = import_from(export.path)
    uploaded_keys = []
    subscriber = ActiveSupport::Notifications.subscribe("service_upload.active_storage") { |*, payload| uploaded_keys << payload[:key] }

    import.check
    error = assert_raises(ZipFile::InvalidFileError) { import.process }

    assert_match(/#{Regexp.escape(forged_entry)} expands beyond its declared 1 bytes/, error.message)
    assert import.reload.failed_due_to_invalid_export?
    assert_operator uploaded_keys.size, :>, 0
    uploaded_keys.each { |key| assert_not ActiveStorage::Blob.service.exist?(key), "partial blob file #{key} was left on storage" }
    assert_equal [ import.file.blob.id ], ActiveStorage::Blob.where(account: import.account).pluck(:id)
    assert_empty Card.where(account: import.account)
    assert_empty Board.where(account: import.account)
    assert_empty User.where(account: import.account)
    assert_empty ActiveStorage::Attachment.where(account: import.account).where.not(record_type: "Account::Import")
    assert import.file.attached?
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    export&.close!
  end

  private
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
