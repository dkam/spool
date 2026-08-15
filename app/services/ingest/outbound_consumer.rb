# frozen_string_literal: true

module Ingest
  # Drains spool.outbound. Each job body is `{ "message_id": <db id> }` — the
  # row is the source of truth, so the job carries a pointer and nothing else,
  # and a job redelivered after its TTR finds delivered_at stamped and skips.
  #
  # Deliberately thin, like InboundConsumer: everything interesting lives in
  # Outbound::Delivery, which the test suite drives directly with no queue in
  # the loop.
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
        Outbound::Delivery::NotDeliverable => e
        # None of these change on retry — a body that doesn't parse, a message
        # that doesn't exist, a message that can never be sent. Bury for
        # inspection rather than cycling five times first.
        log_exception("[OutboundConsumer] undeliverable job, burying", e)
        begin
          job.bury
        rescue
          nil
        end
      rescue Outbound::Http::Rejected => e
        # The provider looked at this exact request and refused it (bad key,
        # unknown domain, refused recipient). The same bytes will be refused
        # again, so bury — visibly, where tuber's stats show it.
        log_exception("[OutboundConsumer] provider rejected send, burying", e)
        begin
          job.bury
        rescue
          nil
        end
      rescue => e
        # Network trouble, a 5xx, rate limiting, missing configuration — all
        # worth retrying, then burying via MAX_RETRIES.
        log_exception("[OutboundConsumer] delivery failed", e)
        safe_finalize(job, :retry)
      end
    end
  end
end
