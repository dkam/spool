class AddDeliveryFailureToMessages < ActiveRecord::Migration[8.1]
  def change
    # The other half of delivered_at. delivery_failed_at says a reply will
    # never go — the recipient's server refused the address, or an agent gave
    # up on it — so the header stops counting it and the backfill stops
    # queueing it. delivery_error is the latest reason a send didn't go,
    # failed for good or not: the thread shows it under the reply.
    add_column :messages, :delivery_failed_at, :datetime
    add_column :messages, :delivery_error, :text
  end
end
