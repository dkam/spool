class AddBlockedAtToCustomers < ActiveRecord::Migration[8.1]
  def change
    add_column :customers, :blocked_at, :datetime
  end
end
