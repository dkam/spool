# frozen_string_literal: true

module Ingest
  # A delivery-status report (RFC 3464) saying one of our replies failed.
  #
  # The customer's side can take a reply and fail it later: a server that
  # checks the mailbox after the SMTP conversation, a forward that dies further
  # on, a relay that retried for days and gave up. The report goes to the
  # envelope sender, which is the support mailbox, and LoopGuard turns it away
  # like any bounce, because it isn't correspondence. Before it goes, Inbound
  # hands it here to find the reply it's about.
  #
  # Only what a machine wrote is read: a message/delivery-status part with a
  # recipient whose Action is "failed", and the Message-ID of the original
  # returned with it (message/rfc822 or text/rfc822-headers). That id is one
  # Spool issued, so a match is proof, the same as LoopGuard's self_sent. A
  # delay warning, a report without the original, the prose part, and the
  # original's References (which name earlier replies) are all ignored, and
  # those reports stay ordinary rejections.
  module Bounce
    DELIVERY_STATUS = "message/delivery-status"
    ORIGINAL = %w[message/rfc822 text/rfc822-headers].freeze

    module_function

    # The reply this mail reports as failed, marked undeliverable — or nil
    # when it isn't a failure report about one of our replies.
    def record!(mail)
      failure = failed_recipient(mail) or return nil
      reply = original_reply(mail) or return nil

      # Read twice after a rewind: it's already marked, and an agent may have
      # dealt with the ticket since.
      unless reply.undeliverable?
        ApplicationRecord.writing { reply.refused!(error_text(failure), at: reported_at(mail)) }
        Rails.logger.warn "[Ingest::Bounce] reply #{reply.id} on ticket #{reply.ticket_id} bounced: #{reply.delivery_error}"
      end

      reply
    end

    # The first recipient the report says failed, as its fields — lowercased
    # names, unfolded values.
    def failed_recipient(mail)
      part = mail.all_parts.find { |p| p.mime_type.to_s.casecmp?(DELIVERY_STATUS) }
      return nil unless part

      # Per-message fields, then a block per recipient; only the recipient
      # blocks carry an Action.
      part.body.decoded.split(/\r?\n[ \t]*\r?\n/)
        .map { |block| fields(block) }
        .find { |f| f["action"].to_s.match?(/\Afailed\b/i) }
    rescue => e
      Rails.logger.warn "[Ingest::Bounce] unreadable delivery report (#{e.class}: #{e.message})"
      nil
    end

    def original_reply(mail)
      part = mail.all_parts.find { |p| ORIGINAL.include?(p.mime_type.to_s.downcase) }
      return nil unless part

      id = ::Mail.new(part.body.decoded).message_id
      ::Message.outbound.find_by(message_id: "<#{id}>") if id.present?
    rescue => e
      Rails.logger.warn "[Ingest::Bounce] unreadable returned original (#{e.class}: #{e.message})"
      nil
    end

    def fields(block)
      block.gsub(/\r?\n[ \t]+/, " ").each_line.with_object({}) do |line, found|
        name, value = line.split(":", 2)
        found[name.strip.downcase] ||= value.squish if value
      end
    end

    # "Bounced by mx.example.com: 550 5.1.1 <…>: User unknown". The receiving
    # server's own words where the report has them, its status code where not.
    def error_text(failure)
      mta = without_type(failure["remote-mta"])
      detail = without_type(failure["diagnostic-code"]).presence ||
        ("status #{failure["status"]}" if failure["status"].present?) ||
        "no reason given"

      "Bounced#{" by #{mta}" if mta.present?}: #{detail}".truncate(Outbound::Delivery::ERROR_LENGTH)
    end

    # "dns; mx.example.com", "smtp; 550 …": the type before the semicolon is
    # for machines.
    def without_type(value)
      value.to_s.sub(/\A[\w-]+\s*;\s*/, "").squish
    end

    def reported_at(mail)
      mail.date&.to_time || Time.current
    rescue
      Time.current
    end
  end
end
