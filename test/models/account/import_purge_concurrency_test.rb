require "test_helper"

# Authoring record: docs/test-audits/handy-954.md.
class Account::ImportPurgeConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Import purge lock")
    @import = Account::Import.create!(account: @account, identity: identities(:david), status: :failed)
    Current.set(account: @account) do
      @import.file.attach(io: StringIO.new("failed export"), filename: "export.zip", content_type: "application/zip")
    end
    @service = ActiveStorage::Blob.service
  end

  teardown do
    @service.singleton_class.remove_method(:delete) if @service.singleton_class.method_defined?(:delete, false)
    ActiveStorage::Attachment.where(record: @import).delete_all
    ActiveStorage::Blob.where(account: @account).find_each(&:purge)
    @import.reload.destroy!
    @account.destroy!
  end

  test "another account writer commits while a failed import deletes storage objects" do
    account_id = @account.id
    writers = []
    writer_states = []
    original_delete = @service.method(:delete)
    @service.define_singleton_method(:delete) do |key|
      writer = Thread.new do
        ApplicationRecord.connection_pool.with_connection do
          Storage::UploadReservation.serialize_account(Account.find(account_id)) { :written }
        end
      end
      writers << writer
      writer_states << (writer.join(2) ? writer.value : :blocked)
      original_delete.call(key)
    end

    @import.purge_failed_files

    assert_equal [ :written ], writer_states
    assert_not @import.reload.file.attached?
  ensure
    writers&.each { |writer| writer.join rescue nil }
  end
end
