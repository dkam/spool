class IngestCursor < ApplicationRecord
  # How far an inbound source has read. Jmap::Poller is the only writer today.
  #
  # The position is opaque to this class on purpose. What "how far" means is the
  # reader's business — for JMAP it is a receivedAt plus the ids sharing that
  # second, and a different source would mean something else entirely. There are
  # no validations here for the same reason: the null constraints are the whole
  # contract, and upsert would skip validations anyway.
  def self.position_for(source)
    find_by(source: source)&.position
  end

  # An upsert rather than find_or_initialize, so two workers polling at once
  # settle on the unique index rather than raising RecordNotUnique.
  #
  # Wraps itself in the writing role for the same reason TicketRead.mark_read!
  # does: a caller reaching this from anywhere the DatabaseSelector has routed to
  # the reading replica would otherwise raise ReadOnlyError, and putting the wrap
  # here means the trap can only be sprung once.
  def self.advance(source, position)
    ApplicationRecord.writing do
      upsert({source: source, position: position, updated_at: Time.current}, unique_by: :source)
    end
  end
end
