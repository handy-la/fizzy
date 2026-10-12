class ConstrainActiveStorageBlobByteSize < ActiveRecord::Migration[8.2]
  def change
    add_check_constraint :active_storage_blobs, "byte_size >= 0", name: "active_storage_blobs_nonnegative_byte_size"
  end
end
