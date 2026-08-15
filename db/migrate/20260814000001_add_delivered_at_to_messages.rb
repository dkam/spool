class AddDeliveredAtToMessages < ActiveRecord::Migration[8.1]
  def change
    # Stamped by Outbound::Delivery once Mailgun accepts the message. Nil on
    # inbound messages and notes always; nil on an outbound message means it
    # has not left Spool yet.
    add_column :messages, :delivered_at, :datetime
  end
end
