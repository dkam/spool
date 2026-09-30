class CreateDroppedMails < ActiveRecord::Migration[8.1]
  def change
    # Inbound mail that reached Spool and did not become a message: turned away
    # by Ingest::LoopGuard ("rejected"), or given up on after its retries
    # ("failed"). No body — the mail itself is still in the mailbox, which Spool
    # never writes to. This is the record of what to look for there, and of
    # where to rewind the poller to fetch it again.
    create_table :dropped_mails do |t|
      t.string :kind, null: false
      t.string :reason, null: false
      t.string :message_id
      t.string :from_email
      t.string :subject
      t.string :source
      t.datetime :received_at
      t.timestamps
    end

    # One row per message, however many times it is dropped: a rewind re-reads
    # a rejected message and rejects it again. Also how a message that is later
    # stored clears its row.
    add_index :dropped_mails, :message_id, unique: true
    add_index :dropped_mails, [:kind, :updated_at]
  end
end
