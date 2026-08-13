class CreateIngestCursors < ActiveRecord::Migration[8.1]
  def change
    # How far each inbound source has read. One row, in practice: the JMAP
    # poller's.
    #
    # This table exists because Spool no longer moves processed mail into a done
    # folder. That move was the only thing needing write access to the mailbox,
    # and a JMAP token cannot be scoped to a folder — so the choice was between
    # a credential that can rewrite every folder on the account, and keeping the
    # high-water mark here. It lives here.
    #
    # position is opaque text: what "how far" means belongs to whoever wrote it.
    # No created_at — updated_at answers the only question anyone asks of this
    # table, which is "when did it last see anything".
    create_table :ingest_cursors do |t|
      t.string :source, null: false
      t.text :position, null: false
      t.datetime :updated_at, null: false
    end

    # Both the uniqueness guarantee for the upsert in IngestCursor.advance and
    # the lookup index for reading it back.
    add_index :ingest_cursors, :source, unique: true
  end
end
