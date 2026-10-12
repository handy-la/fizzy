class Account::DataImportJob < ApplicationJob
  include ActiveJob::Continuable

  self.max_resumptions = 3
  self.resume_errors_after_advancing = false

  TERMINAL_ERRORS = [ Account::DataTransfer::RecordSet::IntegrityError, ZipFile::InvalidFileError,
    Account::Import::InsufficientStorageSpaceError, ActiveJob::Continuation::ResumeLimitError ].freeze

  queue_as :backend
  discard_on(*TERMINAL_ERRORS)
  after_discard do |job, error|
    if import = job.arguments.first
      import.mark_as_failed if import.is_a?(Account::Import)
    end
  end

  def perform(import)
    return if import.failed? || import.completed?

    step :check do |step|
      import.check \
        start: step.cursor,
        callback: ->(record_set:, file:) { step.set!([ record_set.model.name, file ]) }
    end

    step :process do |step|
      import.process \
        start: step.cursor,
        callback: ->(record_set:, files:) { step.set!([ record_set.model.name, files.last ]) }
    end
  rescue *Account::Import::TRANSIENT_ERRORS => e
    # Also resume before the first cursor and when a resumed step has not advanced.
    resume_job(e)
  end
end
