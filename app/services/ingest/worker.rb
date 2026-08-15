# frozen_string_literal: true

module Ingest
  # Maps a worker role to the consumers it runs.
  #
  # At Spool's scale one process could run everything, and in development it
  # does (Procfile.dev starts the "all" role). The split exists so that in
  # production a long maintenance job — dictionary training reads and
  # recompresses a chunk of the corpus — can't sit in front of a customer's
  # email waiting to become a ticket.
  module Worker
    ROLES = {
      # Latency-sensitive: mail in, mail out.
      "mail" => -> { [InboundConsumer.new, OutboundConsumer.new, ActiveJobConsumer.new] },

      # Background work from config/schedule.yml.
      "maintenance" => -> { [DispatchConsumer.new(tube: Tuber::MAINTENANCE_TUBE)] },

      # Everything in one process. Fine for development and for a small
      # single-VPS deploy.
      "all" => -> {
        [InboundConsumer.new, OutboundConsumer.new, ActiveJobConsumer.new,
          DispatchConsumer.new(tube: Tuber::MAINTENANCE_TUBE)]
      }
    }.freeze

    def self.consumers_for(role)
      builder = ROLES[role.to_s] or
        raise ArgumentError, "unknown worker role #{role.inspect} (expected one of: #{ROLES.keys.join(", ")})"
      builder.call
    end
  end
end
