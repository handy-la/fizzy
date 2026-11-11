# Handy #2304: a comment posted twice with the same client token (a double
# click, a retry after a timeout whose first request did land) is one comment.
#
# A nullable column and its index: the add is INSTANT, the index INPLACE,
# LOCK=NONE. Rows without a token never collide: NULLs are distinct in a unique
# index on MySQL and SQLite alike. Each step is skipped when it's already done.
class AddClientTokenToComments < ActiveRecord::Migration[8.2]
  def change
    add_column :comments, :client_token, :string, limit: 64, if_not_exists: true
    add_index :comments, %i[ card_id creator_id client_token ], unique: true, if_not_exists: true
  end
end
