class Attachment < ApplicationRecord
  has_many :message_attachments, dependent: :destroy
  has_many :messages, through: :message_attachments

  validates :sha256, presence: true, uniqueness: true

  # Plain zstd, no dictionary: attachment bytes are usually already compressed
  # (PNG, PDF, docx, zip), and a dictionary trained on prose would do nothing
  # for them. The real win here is dedup — the same signature logo arrives on
  # every message from a given sender.
  def self.store!(bytes, content_type: nil)
    digest = Digest::SHA256.hexdigest(bytes)

    existing = find_by(sha256: digest)
    return existing if existing

    create!(
      sha256: digest,
      content_type: content_type,
      byte_size: bytes.bytesize,
      data: Zstd.compress(bytes, level: 3)
    )
  rescue ActiveRecord::RecordNotUnique
    # Two workers ingesting messages that share an attachment. The unique index
    # settles it; the loser reads the winner's row.
    find_by!(sha256: digest)
  end

  def bytes
    Zstd.decompress(data)
  end

  # Called after unlinking a message. A blob is shared by construction, so it
  # can only go once nothing references it.
  def destroy_if_orphaned!
    destroy! if message_attachments.reload.empty?
  end
end
