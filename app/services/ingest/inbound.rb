# frozen_string_literal: true

module Ingest
  # Turns raw RFC822 into a ticket and a message. The single entry point for
  # inbound mail, whatever delivered it.
  #
  # Keeping this boundary clean is the point: the IMAP poller's only job is to
  # hand raw bytes to `ingest`. Swapping it for a provider webhook later means
  # writing a controller that calls the same method — a config change, not a
  # refactor. The test suite drives it straight from fixture .eml files with no
  # mailbox and no queue in the loop. See docs/ingest.md.
  #
  # Idempotent. Both retry paths — an IMAP re-poll, a provider redelivery — can
  # deliver the same message twice, and the unique index on messages.message_id
  # is what makes the second one a no-op.
  module Inbound
    Result = Struct.new(:outcome, :message, :ticket, :reason, keyword_init: true) do
      def created? = outcome == :created
      def duplicate? = outcome == :duplicate
      def rejected? = outcome == :rejected
    end

    module_function

    def ingest(raw, source: nil)
      mail = ::Mail.read_from_string(raw)

      if (reason = LoopGuard.reject_reason(mail))
        Rails.logger.info "[Ingest] rejected (#{reason})"
        return Result.new(outcome: :rejected, reason: reason)
      end

      message_id = message_id_for(mail, raw)

      # Cheap pre-check. The unique index below is the real guarantee — this
      # only avoids doing the parse-compress-write work to then throw it away.
      if (existing = ::Message.find_by(message_id: message_id))
        Rails.logger.info "[Ingest] duplicate #{message_id}"
        return Result.new(outcome: :duplicate, message: existing, ticket: existing.ticket)
      end

      persist(mail, raw, message_id, source)
    rescue ActiveRecord::RecordNotUnique
      # Lost the race with a concurrent worker ingesting the same message.
      existing = ::Message.find_by(message_id: message_id)
      Result.new(outcome: :duplicate, message: existing, ticket: existing&.ticket)
    end

    def persist(mail, raw, message_id, source)
      split = MimeSplitter.new(mail).call
      from = sender(mail)
      sent_at = mail.date&.to_time || Time.current

      ApplicationRecord.transaction do
        customer = Customer.find_or_create_by_email!(from[:email], name: from[:name])
        ticket = Threader.find_ticket(mail, customer) || Ticket.create!(
          customer: customer,
          subject: clean_subject(mail),
          state: "open",
          last_activity_at: sent_at
        )

        message = ::Message.new(
          ticket: ticket,
          direction: "inbound",
          message_id: message_id,
          in_reply_to: Threader.header_ids(mail, "in-reply-to").first,
          references_header: Threader.header_ids(mail, "references").join(" ").presence,
          from_email: from[:email],
          from_name: from[:name],
          subject: mail.subject.to_s.presence,
          sent_at: sent_at,
          headers: split.headers,
          body: split.body_document,
          body_excerpt: excerpt_for(split),
          # The uncompressed size of exactly what the two blobs hold, so
          # `SELECT SUM(raw_size), SUM(LENGTH(headers_blob) + LENGTH(body_blob))`
          # measures the real compression ratio before adopting a dictionary.
          raw_size: split.headers.bytesize + split.body_document.bytesize
        )
        message.save!

        attach!(message, split.attachments)

        # Inbound reopens: a customer replying to something an agent considered
        # finished is exactly the case that must not stay buried behind a
        # closed filter.
        ticket.record_inbound_activity!(sent_at)

        Rails.logger.info(
          "[Ingest] #{message_id} → ticket #{ticket.id} " \
          "(#{split.attachments.size} attachment(s), source=#{source || "unknown"})"
        )

        Result.new(outcome: :created, message: message, ticket: ticket)
      end
    end

    def attach!(message, parts)
      parts.each do |part|
        attachment = Attachment.store!(part.bytes, content_type: part.content_type)

        MessageAttachment.create!(
          message: message,
          attachment: attachment,
          filename: part.filename,
          content_id: part.content_id
        )
      end
    end

    # The quote-stripped reply, which is what the ticket list and the thread
    # summary show. The full body is kept intact in body_blob — customers
    # top-post inside quoted text often enough that throwing the original away
    # would lose real content.
    def excerpt_for(split)
      source = split.text.presence || html_to_text(split.html)
      return nil if source.blank?

      EmailReplyParser.parse_reply(source).to_s.strip.presence || source.strip.truncate(2000)
    rescue => e
      # A parser that chokes on an odd quoting style must not cost us the
      # message. Fall back to the leading text.
      Rails.logger.warn "[Ingest] excerpt failed (#{e.class}): falling back to truncated body"
      source.to_s.strip.truncate(2000).presence
    end

    # Deliberately crude: this exists only so an HTML-only message still has
    # something searchable and previewable in body_excerpt. The HTML itself is
    # preserved in body_blob and is what gets rendered.
    def html_to_text(html)
      return nil if html.blank?

      html
        .gsub(%r{<(script|style|title|head)[^>]*>.*?</\1>}mi, " ")
        .gsub(%r{<br\s*/?>}i, "\n")
        .gsub(%r{</p>}i, "\n\n")
        .gsub(/<[^>]+>/, " ")
        .then { |s| CGI.unescapeHTML(s) }
        .gsub(/[ \t]+/, " ")
        .gsub(/\n{3,}/, "\n\n")
        .strip
    end

    # Reply-To wins over From. A form mailer (a contact form, Booko's issue
    # reports) has to send from its own authenticated domain, so the human who
    # filled the form travels in Reply-To — and an agent's reply is going to
    # that address regardless, so the ticket should belong to it too. The full
    # From header survives in headers_blob if it's ever needed.
    def sender(mail)
      field = [:reply_to, :from].find { |f| address_of(mail, f) } || :from
      name = begin
        mail[field]&.display_names&.first
      rescue
        nil
      end

      {email: address_of(mail, field), name: name.presence}
    rescue
      {email: nil, name: nil}
    end

    def address_of(mail, field)
      mail.public_send(field)&.first.to_s.strip.downcase.presence
    rescue
      nil
    end

    # Strips the Re:/Fwd: prefixes and Spool's own [#123] tag, so a new ticket
    # gets a clean title rather than "Re: Re: Fwd: ...".
    def clean_subject(mail)
      subject = mail.subject.to_s
        .gsub(Ticket::SUBJECT_TAG, "")
        .sub(/\A(\s*(re|aw|fwd?|vs|sv|antw)\s*(\[\d+\])?\s*:\s*)+/i, "")
        .squish

      subject.presence
    end

    # Mail without a Message-ID exists, and something has to key idempotency.
    # A content hash is the only option that still dedups a redelivery of the
    # same bytes — a random id would make every retry a new ticket. The
    # `.invalid` TLD is reserved by RFC 2606 precisely so it can never collide
    # with a real id.
    def message_id_for(mail, raw)
      id = begin
        mail.message_id
      rescue
        nil
      end
      return "<#{id}>" if id.present?

      "<sha256-#{Digest::SHA256.hexdigest(raw)}@spool.invalid>"
    end

    def sender_missing?(from)
      from[:email].blank?
    end
  end
end
