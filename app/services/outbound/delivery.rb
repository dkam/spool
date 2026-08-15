# frozen_string_literal: true

module Outbound
  # Turns a stored outbound Message row into the email it was always meant to
  # be, and hands it to a transport. Message.compose! owns creating the row
  # (Message-ID, threading headers, body envelope); this module owns nothing
  # but the send — building the MIME from what the row already carries, and
  # stamping delivered_at once the transport accepts it.
  #
  # Two transports, one seam (deliver_mime(to:, mime:) → a string for the log):
  # Outbound::Smtp and Outbound::Mailgun. SMTP wins when its env is set — the
  # common case for a local relay or an inbox provider with SMTP creds (e.g.
  # Fastmail) — with Mailgun as the fallback for the subdomain/DKIM setup. Both
  # share SPOOL_MAILBOX as the From: header, so the customer's reply lands
  # back in the folder the poller reads regardless of transport.
  #
  # Configuration is env-only and optional, the JMAP poller's pattern: with no
  # transport credentials nothing enqueues and nothing sends, so a checkout
  # without credentials composes replies that simply stay stored. `bin/rails
  # outbound:backfill` queues whatever accumulated once the credentials exist.
  module Delivery
    # This send can never work: the row isn't an outbound message, or there is
    # no address to send it to. The consumer buries on it rather than retrying.
    class NotDeliverable < StandardError; end

    # Delivery credentials are missing in an environment that queued a send —
    # retryable, because an operator setting the env vars is the fix.
    class NotConfigured < StandardError; end

    module_function

    def smtp_configured?
      Outbound::Smtp.configured? && ENV["SPOOL_MAILBOX"].present?
    end

    def mailgun_configured?
      ENV["MAILGUN_API_KEY"].present? &&
        ENV["MAILGUN_DOMAIN"].present? &&
        ENV["SPOOL_MAILBOX"].present?
    end

    def configured?
      smtp_configured? || mailgun_configured?
    end

    # SMTP takes precedence when its env is set — the common case for a local
    # relay or an inbox provider with SMTP creds. Mailgun is the fallback for
    # the subdomain/DKIM setup. SPOOL_MAILBOX is shared (the From: header), so
    # both require it; configured? gates the whole thing.
    def transport
      return Smtp.new if smtp_configured?
      if mailgun_configured?
        Mailgun.new(
          api_key: ENV.fetch("MAILGUN_API_KEY"),
          domain: ENV.fetch("MAILGUN_DOMAIN"),
          api_base: ENV["MAILGUN_API_BASE"]
        )
      end
    end

    # Put a send on spool.outbound. Called by Message.compose! after the row is
    # committed. Failure is logged, not raised: the reply is already saved, and
    # making the agent's compose blow up over a down queue invites the real
    # failure — a re-sent duplicate. The backfill task re-queues anything that
    # slipped through.
    def enqueue(message)
      return unless message.outbound? && configured?

      # idp so the same message can't sit on the tube twice — makes backfill
      # safe to run at any time, even with sends already in flight.
      Ingest::Tuber.put(
        Ingest::Tuber::OUTBOUND_TUBE,
        {message_id: message.id},
        idp: "outbound-#{message.id}"
      )
    rescue => e
      Rails.logger.error "[Outbound::Delivery] enqueue failed for message #{message.id}: #{e.class}: #{e.message}"
      Sentry.capture_exception(e, tags: {service: "outbound"})
      nil
    end

    # Send one message. Idempotent via delivered_at: a job redelivered after
    # its TTR, or a backfill racing a live send, finds the stamp and skips.
    # The stamp is written after the transport accepts, so the crash window is
    # "accepted but not stamped" — a possible duplicate email, never a lost
    # one, which is the right side to err on.
    def deliver!(message, transport: self.transport)
      raise NotDeliverable, "message #{message.id} is #{message.direction}, not outbound" unless message.outbound?
      return :already_delivered if message.delivered_at

      to = message.ticket.customer.email
      raise NotDeliverable, "ticket #{message.ticket_id}'s customer has no email address" if to.blank?
      raise NotConfigured, "set SMTP_ADDRESS + SPOOL_MAILBOX for SMTP, or MAILGUN_API_KEY + MAILGUN_DOMAIN + SPOOL_MAILBOX for Mailgun" unless configured?

      provider_id = transport.deliver_mime(to: to, mime: mime_for(message).to_s)
      message.update!(delivered_at: Time.current)

      Rails.logger.info "[Outbound::Delivery] delivered message #{message.id} to #{to} via #{transport_name(transport)} (#{provider_id})"
      :delivered
    end

    # The RFC822 message, built entirely from what compose! stored. From: stays
    # the support address — not a Mailgun one — so the customer's reply lands
    # back in the Fastmail folder the poller reads.
    def mime_for(message)
      mail = Mail.new
      mail.charset = "UTF-8"
      mail.from = ENV.fetch("SPOOL_MAILBOX")
      mail.to = message.ticket.customer.email
      mail.subject = message.subject
      mail.date = message.sent_at
      mail.message_id = message.message_id
      mail.in_reply_to = message.in_reply_to if message.in_reply_to.present?
      mail.references = message.references_header if message.references_header.present?
      mail.body = message.body_text.to_s
      mail
    end

    def transport_name(transport)
      transport.class.name.demodulize.downcase
    end
  end
end
