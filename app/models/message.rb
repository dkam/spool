class Message < ApplicationRecord
  include CompressedColumn

  DIRECTIONS = %w[inbound outbound note].freeze

  belongs_to :ticket
  belongs_to :agent, optional: true

  has_many :message_attachments, dependent: :destroy
  has_many :attachments, through: :message_attachments

  # `headers` and `body` are plain strings to everything outside this line; the
  # zstd blobs and dictionary ids underneath are an implementation detail of
  # CompressedColumn.
  compressed_column :headers, kind: :headers
  compressed_column :body, kind: :body

  validates :direction, presence: true, inclusion: {in: DIRECTIONS}
  validates :message_id, presence: true, uniqueness: true

  scope :chronological, -> { order(:sent_at, :id) }
  scope :inbound, -> { where(direction: "inbound") }
  scope :outbound, -> { where(direction: "outbound") }
  scope :notes, -> { where(direction: "note") }
  scope :emailed, -> { where(direction: %w[inbound outbound]) }

  def inbound? = direction == "inbound"
  def outbound? = direction == "outbound"
  def note? = direction == "note"

  # `body` holds a JSON document, not display text: a message legitimately has
  # both a text/plain and a text/html rendering and discarding either loses
  # something — the HTML is what the customer actually saw, the plain text is
  # what quotes and searches cleanly. Ingest::MimeSplitter writes every row, so
  # the format is guaranteed; these are the accessors views should use.
  def body_document
    @body_document ||= begin
      raw = body
      raw.present? ? JSON.parse(raw) : {}
    rescue JSON::ParserError
      # A row written before the JSON envelope existed, or by hand in a console.
      # Treat the whole thing as plain text rather than blanking the message.
      {"text" => body}
    end
  end

  def body_text = body_document["text"].presence

  def body_html = body_document["html"].presence

  # What to render in the thread: the HTML the customer sent if there is any,
  # otherwise the plain text. Callers are responsible for sanitising the HTML —
  # it is attacker-controlled by definition.
  def body_for_display = body_html || body_text

  # Structured ticket metadata stamped by the sending application as
  # X-Spool-Meta-* headers — a Booko form reports the product, region and IP
  # this way. Parsed from the stored header block on demand rather than at
  # ingest: the blob keeps every header anyway, so this also works on mail
  # that arrived before its sender learned the convention. Keys are the
  # header suffix, downcased: {"product" => "97803…", "product-url" => "…"}.
  def spool_meta
    @spool_meta ||= headers.to_s
      .gsub(/\r?\n[ \t]+/, " ") # unfold RFC 5322 continuation lines
      .each_line(chomp: true)
      .filter_map do |line|
        name, value = line.split(":", 2)
        suffix = name.to_s[/\Ax-spool-meta-(.+)\z/i, 1]
        [suffix.downcase, Mail::Encodings.value_decode(value.strip)] if suffix && value.to_s.strip.present?
      end.to_h
  end

  def reload(*)
    @body_document = nil
    @spool_meta = nil
    super
  end

  # The References header for a reply to this message: the existing chain plus
  # this message's own id. Correct threading in the customer's client depends
  # on getting this right, and so does re-threading when they reply back.
  def reply_references
    [references_header.to_s.split(/\s+/), message_id].flatten.compact_blank.uniq.join(" ")
  end

  # The compose path: an agent's reply or internal note. The one place outbound
  # messages and notes are created, so that the things delivery depends on
  # can't be forgotten — a Spool-issued Message-ID, the threading headers built
  # from the message being replied to, and the JSON body envelope.
  #
  # The row is the source of truth and delivery is asynchronous: a reply is
  # committed first, then queued for Outbound::Delivery. With no transport
  # configured the queueing is skipped and the row simply stays stored —
  # `bin/rails outbound:backfill` sends the accumulation once credentials
  # exist.
  def self.compose!(ticket:, agent:, text:, direction: "outbound", subject: nil)
    raise ArgumentError, "direction must be outbound or note" unless
      %w[outbound note].include?(direction)

    parent = ticket.last_emailed_message
    document = JSON.generate({"text" => text, "html" => nil})
    sent_at = Time.current

    message = ApplicationRecord.transaction do
      created = create!(
        ticket: ticket,
        agent: agent,
        direction: direction,
        message_id: generate_message_id,
        # Notes are never emailed, so they carry no threading headers — leaving
        # them off is what keeps a note from ever looking like a sent reply.
        in_reply_to: (parent&.message_id if direction == "outbound"),
        references_header: (parent&.reply_references if direction == "outbound"),
        subject: subject.presence || ticket.tagged_subject,
        sent_at: sent_at,
        body: document,
        body_excerpt: text.to_s.strip.presence,
        raw_size: document.bytesize
      )

      # A note is internal, so it doesn't hand the ball to the customer and
      # doesn't change the ticket's state.
      if direction == "outbound"
        ticket.record_outbound_activity!(sent_at)
      else
        ticket.update!(last_activity_at: sent_at)
      end

      created
    end

    # After the commit, never inside it: a queued send racing an uncommitted
    # row would find nothing to deliver.
    Outbound::Delivery.enqueue(message)

    message
  end

  # Message-IDs Spool issues. The domain must be one Spool controls, because
  # LoopGuard recognises our own mail echoed back by matching on these, and
  # threading on the customer's reply depends on them being stable and unique.
  def self.generate_message_id(domain: nil)
    domain ||= ENV["SPOOL_MESSAGE_ID_DOMAIN"].presence ||
      ENV.fetch("SPOOL_HOST", "spool.invalid").split(":").first

    "<#{SecureRandom.uuid}@#{domain}>"
  end

  # Full-text search over subject and body_excerpt. Returns messages ordered by
  # FTS5 relevance (bm25 ranks best matches lowest, hence ascending).
  def self.search(query)
    sanitized = Search::Fts.sanitize(query)
    return none if sanitized.blank?

    ids_with_rank = connection.select_rows(
      sanitize_sql_array([
        "SELECT rowid, bm25(messages_fts) FROM messages_fts WHERE messages_fts MATCH ? ORDER BY 2 LIMIT 200",
        sanitized
      ])
    )
    return none if ids_with_rank.empty?

    ids = ids_with_rank.map(&:first)
    where(id: ids).in_order_of(:id, ids)
  end
end
