# frozen_string_literal: true

module Ingest
  # Drains spool.inbound. Each job body is `{ "raw": "<base64 RFC822>" }` —
  # base64 because a JSON string can't carry arbitrary 8-bit MIME bytes intact,
  # and re-encoding the message to make it JSON-safe would corrupt exactly the
  # attachments we're trying to store faithfully.
  #
  # The consumer is deliberately thin: everything interesting lives in
  # Ingest::Inbound, which is driven directly by fixture .eml files in the test
  # suite with no queue in the loop. Swapping the IMAP poller for a provider
  # webhook later means writing a controller that calls Ingest::Inbound.ingest —
  # not touching any of this. See docs/ingest.md.
  class InboundConsumer < TubeConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: Tuber::INBOUND_TUBE, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      jobs.each do |job|
        body = JSON.parse(job.body)
        raw = Base64.decode64(body.fetch("raw"))

        result = Ingest::Inbound.ingest(raw, source: body["source"], received_at: body["received_at"])
        Rails.logger.info "[InboundConsumer] #{result.outcome}#{" ticket=#{result.ticket.id}" if result.ticket}"

        job.delete
      rescue ::Tuber::NotFoundError
        # Reservation already expired and someone else took it.
        nil
      rescue JSON::ParserError, KeyError => e
        # A malformed body will never parse, so retrying is pointless.
        log_exception("[InboundConsumer] unprocessable job body", e)
        safe_finalize(job, :give_up, e)
      rescue => e
        log_exception("[InboundConsumer] ingest failed", e)
        safe_finalize(job, :retry, e)
      end
    end

    # The mail is still in the mailbox; this is the note of what to look for
    # and where to rewind the poller to (`bin/rails jmap:rewind`). Whatever the
    # body still yields goes in — for a body that won't parse, only the reason.
    def gave_up(job, error)
      body = begin
        JSON.parse(job.body)
      rescue JSON::ParserError
        {}
      end

      DroppedMail.record!(
        kind: "failed",
        reason: "#{error.class}: #{error.message}",
        raw: body["raw"] && Base64.decode64(body["raw"]),
        source: body["source"],
        received_at: body["received_at"]
      )
    end
  end
end
