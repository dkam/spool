# frozen_string_literal: true

module Ingest
  # Drains spool.outbound. Each job body is `{ "message_id": <db id> }` — the
  # row is the source of truth, so the job carries a pointer and nothing else,
  # and a job redelivered after its TTR finds delivered_at stamped and skips.
  #
  # Deliberately thin, like InboundConsumer: everything interesting lives in
  # Outbound::Delivery, which the test suite drives directly with no queue in
  # the loop.
  #
  # A send given up on is deleted, never buried: the reply stays a row with no
  # delivered_at, which the thread and the header both show, and
  # `bin/rails outbound:backfill` queues it again. A buried job would hold its
  # `idp:outbound-<id>` key and make that backfill a silent no-op.
  class OutboundConsumer < TubeConsumer
    def initialize(batch_size: DEFAULT_BATCH_SIZE)
      super(tube: Tuber::OUTBOUND_TUBE, batch_size: batch_size)
    end

    private

    def process_batch(jobs)
      jobs.each do |job|
        body = JSON.parse(job.body)
        message = Message.find(body.fetch("message_id"))

        outcome = Outbound::Delivery.deliver!(message)
        Rails.logger.info "[OutboundConsumer] #{outcome} message=#{message.id}"

        job.delete
      rescue ::Tuber::NotFoundError
        # Reservation already expired and someone else took it.
        nil
      rescue JSON::ParserError, KeyError, ActiveRecord::RecordNotFound,
        Outbound::Delivery::NotDeliverable, Outbound::Rejected => e
        # None of these change on retry — a body that doesn't parse, a message
        # that doesn't exist, a message that can never be sent, or a transport
        # that looked at this exact send and refused it (bad key, unknown
        # domain, refused recipient, permanent SMTP failure).
        log_exception("[OutboundConsumer] undeliverable", e)
        safe_finalize(job, :give_up, e)
      rescue => e
        # Network trouble, a 5xx, rate limiting, missing configuration — all
        # worth retrying, then giving up on via MAX_RETRIES.
        log_exception("[OutboundConsumer] delivery failed", e)
        safe_finalize(job, :retry, e)
      end
    end
  end
end
