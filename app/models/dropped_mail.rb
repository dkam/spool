class DroppedMail < ApplicationRecord
  # Inbound mail that reached Spool and did not become a message.
  #
  #   rejected  Ingest::LoopGuard turned it away: an auto-reply, a bounce, bulk
  #             or list mail. Deliberate, and routine.
  #   failed    ingest raised on every retry and Ingest::InboundConsumer gave
  #             up on it. Never routine — the header says so until it clears.
  #
  # Either way the mail is still in the mailbox, because Spool never writes to
  # it. A row is the answer to "why isn't this email in Spool?", and for a
  # failure it is also where to rewind the poller to fetch it again (see
  # `bin/rails jmap:rewind`). Storing the message later deletes its row, so a
  # failure clears itself once the message is in.
  KINDS = %w[rejected failed].freeze

  validates :kind, inclusion: {in: KINDS}

  scope :rejected, -> { where(kind: "rejected") }
  scope :failed, -> { where(kind: "failed") }
  scope :latest_first, -> { order(updated_at: :desc) }

  # `raw` is parsed here rather than by the caller, because the caller is
  # sometimes recording that the parse itself blew up. Whatever can't be read
  # out of it is left blank; the row is still worth having for its reason and
  # its receivedAt.
  #
  # Keyed on Message-ID, so a message dropped twice (a rewind re-reads it) is
  # one row, updated.
  def self.record!(kind:, reason:, raw: nil, mail: nil, source: nil, received_at: nil)
    mail ||= parse(raw)

    attrs = {
      kind: kind,
      reason: reason.to_s.truncate(255),
      message_id: (Ingest::Inbound.message_id_for(mail, raw.to_s) if mail),
      from_email: header(mail) { |m| m.from&.first.to_s.downcase },
      subject: header(mail) { |m| m.subject.to_s.truncate(255) },
      source: source,
      received_at: parse_time(received_at) || header(mail) { |m| m.date&.to_time }
    }

    ApplicationRecord.writing do
      if attrs[:message_id]
        upsert(attrs, unique_by: :message_id)
      else
        create!(attrs)
      end
    end
  end

  # The message is in: whatever kept it out is no longer true.
  def self.clear!(message_id)
    where(message_id: message_id).delete_all
  end

  def self.parse(raw)
    ::Mail.read_from_string(raw) if raw.present?
  rescue
    nil
  end

  def self.header(mail)
    yield(mail).presence if mail
  rescue
    nil
  end

  def self.parse_time(value)
    return value if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)

    Time.iso8601(value) if value.present?
  rescue ArgumentError
    nil
  end

  private_class_method :parse, :header, :parse_time
end
