class CreateMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :messages do |t|
      t.references :ticket, null: false, foreign_key: true

      # The authoring agent for outbound messages and internal notes; null for
      # inbound, which came from the customer.
      t.references :agent, foreign_key: true

      # inbound | outbound | note. Notes share the thread but are never emailed.
      t.string :direction, null: false

      # The idempotency key for the whole ingest pipeline. Both retry paths
      # (an IMAP re-poll, a provider redelivery) can deliver the same message
      # twice; the unique index is what makes the second one a no-op.
      t.string :message_id, null: false, index: {unique: true}

      # Threading. in_reply_to and references_header are matched against
      # messages.message_id to find the ticket a reply belongs to.
      t.string :in_reply_to, index: true
      t.text :references_header

      t.string :from_email
      t.string :from_name
      t.string :subject
      t.datetime :sent_at, index: true

      # zstd, compressed against the dictionary named by *_dictionary_id, or
      # plain zstd when that is nil. See docs/compression.md.
      #
      # There is deliberately no raw MIME column: messages are stored split,
      # and byte-identical reassembly is abandoned on purpose — reconstructing
      # exact MIME from parsed parts is unwinnable, and the upstream mailbox
      # retains a copy if forensics are ever needed.
      t.binary :headers_blob
      t.binary :body_blob

      # Quote-stripped reply text, uncompressed on purpose: it's read on every
      # page render and indexed by FTS5. Compressing the hot path to save
      # kilobytes is backwards.
      t.text :body_excerpt

      t.integer :headers_dictionary_id
      t.integer :body_dictionary_id

      # Uncompressed byte size, kept so compression ratio can be measured
      # against the real corpus before adopting a trained dictionary.
      t.integer :raw_size

      t.timestamps
    end
  end
end
