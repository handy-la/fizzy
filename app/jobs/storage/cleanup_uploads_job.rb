class Storage::CleanupUploadsJob < ApplicationJob
  def perform
    Storage::UploadReservation.cleanup
  end
end
