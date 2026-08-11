class CreateTicketReads < ActiveRecord::Migration[8.1]
  def change
    # Per-agent read state. Not a boolean on tickets: with more than one agent,
    # "read" is a fact about a person, not about a ticket.
    #
    # A ticket is unread for an agent when there is no row here, or when
    # last_read_at is older than the ticket's last_activity_at — so a customer
    # replying to a thread you had read makes it unread again, which is the
    # whole point.
    #
    # No timestamps: created_at would duplicate the first last_read_at and
    # updated_at would duplicate every later one.
    create_table :ticket_reads do |t|
      t.references :agent, null: false, foreign_key: true
      t.references :ticket, null: false, foreign_key: true
      t.datetime :last_read_at, null: false
    end

    # Both the uniqueness guarantee for the upsert in TicketRead.mark_read! and
    # the lookup index for "has this agent read this ticket".
    add_index :ticket_reads, [:agent_id, :ticket_id], unique: true
  end
end
