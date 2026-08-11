class CreateAttachments < ActiveRecord::Migration[8.1]
  def change
    # Content-addressed by sha256. Corporate email signatures attach the same
    # logo to every message, so dedup by hash is a far larger win than
    # compression on exactly the content that compresses worst — and the two
    # compose: the blob is stored plain-zstd once.
    #
    # Reference-count via message_attachments before deleting a blob.
    create_table :attachments do |t|
      t.string :sha256, null: false, index: {unique: true}
      t.string :content_type
      t.integer :byte_size

      # Plain zstd, no dictionary. Attachment bytes are usually already
      # compressed (PNG, PDF, zip); a corpus dictionary trained on prose would
      # do nothing for them, and training on them would dilute the prose dict.
      t.binary :data

      t.timestamps
    end

    create_table :message_attachments do |t|
      t.references :message, null: false, foreign_key: true
      t.references :attachment, null: false, foreign_key: true

      # Per-message, not per-blob: the same logo arrives as "logo.png" from one
      # sender and "image001.png" from another.
      t.string :filename

      # Set for inline parts, so cid: references in an HTML body can resolve.
      t.string :content_id
    end
  end
end
