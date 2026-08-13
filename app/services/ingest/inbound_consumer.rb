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

        result = Ingest::Inbound.ingest(raw, source: body["source"])
        Rails.logger.info "[InboundConsumer] #{result.outcome}#{" ticket=#{result.ticket.id}" if result.ticket}"

        job.delete
      rescue ::Tuber::NotFoundError
        # Reservation already expired and someone else took it.
        nil
      rescue JSON::ParserError, KeyError => e
        # A malformed body will never parse, so retrying is pointless — bury it
        # for inspection rather than cycling it for the next five attempts.
        log_exception("[InboundConsumer] unprocessable job body, burying", e)
        begin
          job.bury
        rescue
          nil
        end
      rescue => e
        log_exception("[InboundConsumer] ingest failed", e)
        safe_finalize(job, :retry)
      end
    end
  end
end
