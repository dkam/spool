# frozen_string_literal: true

namespace :outbound do
  desc "Queue every stored outbound message that has not been delivered yet"
  task backfill: :environment do
    # Two ways a sent reply ends up stored but not queued: it was composed
    # before a transport was configured (including everything from before
    # delivery existed at all), or the queue was down at the moment of
    # compose. Either way the row is complete and correct — this just puts it
    # on the tube. Safe to run at any time: the per-message idp key suppresses
    # duplicates of anything already queued, and delivered_at skips anything
    # already sent.
    unless Outbound::Delivery.configured?
      abort "No outbound transport is configured — set SMTP_ADDRESS + SPOOL_MAILBOX for SMTP, " \
            "or MAILGUN_API_KEY + MAILGUN_DOMAIN + SPOOL_MAILBOX for Mailgun."
    end

    undelivered = Message.outbound.where(delivered_at: nil).chronological
    puts "Queueing #{undelivered.count} undelivered outbound message(s)…"

    undelivered.each do |message|
      Outbound::Delivery.enqueue(message)
      puts "  queued message #{message.id} (ticket #{message.ticket_id}, composed #{message.sent_at})"
    end
  end
end
