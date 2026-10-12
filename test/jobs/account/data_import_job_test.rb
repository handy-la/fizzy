require "test_helper"

class Account::DataImportJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  test "performs import via continuable steps" do
    source_account = accounts("37s")
    exporter = users(:david)
    identity = exporter.identity

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

    Account::DataImportJob.perform_now(import)

    assert import.reload.completed?
  ensure
    export_tempfile&.close
    export_tempfile&.unlink
  end

  test "resumes a transient error without a failure email and eventually completes" do
    import = import_with_records
    Account::Import.any_instance.stubs(:ensure_sufficient_storage_space).returns(nil).then.raises(Errno::ECONNRESET).then.returns(nil)

    assert_enqueued_with(job: Account::DataImportJob) do
      assert_no_enqueued_emails do
        Account::DataImportJob.perform_now(import)
      end
    end
    assert import.reload.processing?

    execute_next_resumption
    assert import.reload.completed?
    assert_enqueued_email_with ImportMailer, :completed, args: [ import.identity, import.account ]
  end

  test "a valid record followed by invalid JSON fails once without resuming" do
    import = import_with_records("{")
    job = Account::DataImportJob.new(import)

    assert_no_enqueued_jobs only: Account::DataImportJob do
      assert_enqueued_emails 1 do
        job.perform_now
      end
    end

    assert import.reload.failed_due_to_invalid_export?
    assert_equal [ "Tag", "data/tags/0000000000000000000000001.json" ], job.continuation.to_h.fetch("current").last
    assert_enqueued_email_with ImportMailer, :failed, args: [ import ]

    assert_no_enqueued_emails do
      assert_no_enqueued_jobs only: Account::DataImportJob do
        Account::DataImportJob.perform_now(import)
      end
    end
  end

  test "invalid JSON during process is terminal even after a completed check step" do
    import = import_with_records("{")
    job = Account::DataImportJob.new(import)
    job.continuation = ActiveJob::Continuation.new(job, { "completed" => [ "check" ] })

    assert_no_enqueued_jobs only: Account::DataImportJob do
      assert_enqueued_emails 1 do
        job.perform_now
      end
    end
    assert import.reload.failed_due_to_invalid_export?
  end

  test "an unexpected error after advancing is terminal and reported once" do
    import = import_with_records
    Account::Import.any_instance.stubs(:process).raises(NoMethodError, "unexpected bug")

    assert_no_enqueued_jobs only: Account::DataImportJob do
      assert_enqueued_emails 1 do
        assert_raises(NoMethodError) { Account::DataImportJob.perform_now(import) }
      end
    end
    assert import.reload.failed?
    assert_nil import.failure_reason
  end

  test "transient failures stop after three serialized resumptions with one failure email" do
    import = import_with_records
    # Only the first attempt completes check; resumed process makes no progress.
    Account::Import.any_instance.stubs(:process).raises(Errno::ECONNRESET)

    assert_no_enqueued_emails { Account::DataImportJob.perform_now(import) }
    2.times do
      assert_no_enqueued_emails { execute_next_resumption }
    end
    assert import.reload.processing?

    assert_no_enqueued_jobs only: Account::DataImportJob do
      assert_enqueued_emails 1 do
        execute_next_resumption
      end
    end
    assert import.reload.failed?
    assert_enqueued_email_with ImportMailer, :failed, args: [ import ]
  end

  [ ActiveRecord::Deadlocked, Net::ReadTimeout ].each do |error_class|
    test "#{error_class} before the first cursor has bounded resumptions and one terminal email" do
      import = import_with_records
      Account::Import.any_instance.stubs(:ensure_sufficient_storage_space).raises(error_class)

      assert_no_enqueued_emails { Account::DataImportJob.perform_now(import) }
      2.times do
        assert_no_enqueued_emails { execute_next_resumption }
      end
      assert import.reload.processing?

      assert_no_enqueued_jobs only: Account::DataImportJob do
        assert_enqueued_emails 1 do
          execute_next_resumption
        end
      end
      assert import.reload.failed?
    end
  end

  test "discards the job and marks the import failed_due_to_conflict when a crafted export duplicates a unique key" do
    source_account = accounts("37s")
    exporter = users(:david)
    identity = exporter.identity

    boards(:writebook).publish

    export = Account::Export.create!(account: source_account, user: exporter)
    export.build

    export_tempfile = Tempfile.new([ "export", ".zip" ])
    export.file.open { |f| FileUtils.cp(f.path, export_tempfile.path) }

    source_account.destroy!

    tampered_tempfile = duplicate_publication_key_in(export_tempfile)

    target_account = Account.create_with_owner(account: { name: "Import Test" }, owner: { identity: identity, name: exporter.name })
    import = Account::Import.create!(identity: identity, account: target_account)
    Current.set(account: target_account) do
      import.file.attach(io: File.open(tampered_tempfile.path), filename: "export.zip", content_type: "application/zip")
    end

    assert_nothing_raised do
      assert_no_enqueued_jobs only: Account::DataImportJob do
        Account::DataImportJob.perform_now(import)
      end
    end

    assert import.reload.failed_due_to_conflict?
  ensure
    export_tempfile&.close
    export_tempfile&.unlink
    tampered_tempfile&.close
    tampered_tempfile&.unlink
  end

  private
    def import_with_records(invalid_content = nil)
      account = Account.create_with_owner(account: { name: "Import Test" }, owner: { identity: identities(:david), name: "David" })
      import = Account::Import.create!(account: account, identity: identities(:david))
      tempfile = Tempfile.new([ "records", ".zip" ])
      tempfile.binmode
      writer = ZipFile::Writer.new(tempfile)
      writer.add_file("data/account.json", account.as_json.merge(join_code: account.join_code.as_json).to_json)
      tag = tags(:web).attributes.merge("id" => "0000000000000000000000001", "account_id" => ActiveRecord::Type::Uuid.generate)
      writer.add_file("data/tags/#{tag['id']}.json", tag.to_json)
      writer.add_file("data/tags/0000000000000000000000002.json", invalid_content) if invalid_content
      writer.close
      tempfile.rewind
      Current.set(account: account) do
        import.file.attach(io: tempfile, filename: "export.zip", content_type: "application/zip")
      end
      import
    ensure
      tempfile&.close!
    end

    def execute_next_resumption
      queued = enqueued_jobs.find { |entry| entry[:job] == Account::DataImportJob }
      assert queued, "expected a serialized import resumption"
      enqueued_jobs.delete(queued)
      ActiveJob::Base.execute(queued)
    end

    # Simulates a hand-edited export: an extra board_publications record with a
    # fresh id but a key copied from another record in the same export.
    def duplicate_publication_key_in(export_tempfile)
      tampered = Tempfile.new([ "tampered_export", ".zip" ])
      tampered.binmode

      File.open(export_tempfile.path, "rb") do |file|
        reader = ZipFile::Reader.new(file)
        writer = ZipFile::Writer.new(tampered)

        reader.glob("*").reject { |name| name.end_with?("/") }.each do |entry|
          writer.add_file(entry, reader.read(entry))
        end

        publication_file = reader.glob("data/board_publications/*.json").first
        publication_data = JSON.parse(reader.read(publication_file))
        publication_data["id"] = ActiveRecord::Type::Uuid.generate
        writer.add_file("data/board_publications/#{publication_data['id']}.json", publication_data.to_json)

        writer.close
      end

      tampered.rewind
      tampered
    end
end
