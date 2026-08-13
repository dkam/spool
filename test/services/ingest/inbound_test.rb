# frozen_string_literal: true

require "test_helper"

# The whole inbound pipeline, driven straight from fixture .eml files. No IMAP,
# no tuber, no ActionMailbox conductor — Ingest::Inbound takes raw bytes, so the
# test can too. This is where threading, MIME splitting and loop rejection get
# to be correct before any live mailbox is involved.
class Ingest::InboundTest < ActiveSupport::TestCase
  # --- opening a ticket ----------------------------------------------------

  test "a first message opens a ticket and creates the customer" do
    result = ingest(:new_ticket)

    assert result.created?
    assert_equal "ada@example.com", result.ticket.customer.email
    assert_equal "Ada Lovelace", result.ticket.customer.name
    assert_equal "open", result.ticket.state
    assert_equal "Printer catches fire when printing", result.ticket.subject
    assert_equal "inbound", result.message.direction
    assert_equal "<CAF1a2b3c4d5@mail.example.com>", result.message.message_id
  end

  test "message body and headers round-trip through compression" do
    message = ingest(:new_ticket).message.reload

    assert_includes message.body_text, "printer catches fire"
    assert_includes message.headers, "Message-ID: <CAF1a2b3c4d5@mail.example.com>"

    # Stored as a zstd frame rather than as the text. (Not asserting the
    # plaintext is absent: zstd stores incompressible input as a raw literal
    # block, so a short body stays legible inside its frame.)
    assert_equal Encoding::BINARY, message.body_blob.encoding
    assert message.body_blob.start_with?("\x28\xB5\x2F\xFD".b)

    # Ships with no dictionary; the row records that it was written without one.
    assert_nil message.body_dictionary_id
    assert_nil message.headers_dictionary_id
  end

  test "sent_at comes from the Date header, not the clock" do
    message = ingest(:new_ticket).message

    assert_equal Time.parse("Tue, 11 Aug 2026 09:14:20 +1000"), message.sent_at
  end

  # --- idempotency ---------------------------------------------------------

  test "re-delivering the same message is a no-op" do
    first = ingest(:new_ticket)

    assert_no_difference ["Message.count", "Ticket.count", "Customer.count"] do
      second = ingest(:new_ticket)

      assert second.duplicate?
      assert_equal first.message.id, second.message.id
    end
  end

  test "a message with no Message-ID gets a deterministic one, so redelivery still dedups" do
    first = ingest(:no_message_id)
    assert first.created?
    assert_match(/\A<sha256-[0-9a-f]{64}@spool\.invalid>\z/, first.message.message_id)

    assert_no_difference "Message.count" do
      assert ingest(:no_message_id).duplicate?
    end
  end

  # --- threading -----------------------------------------------------------

  test "In-Reply-To threads onto the existing ticket" do
    ticket = ingest(:new_ticket).ticket
    outbound_reply(ticket, "<spool-outbound-0001@spool.test>")

    result = ingest(:reply_in_reply_to)

    assert result.created?
    assert_equal ticket.id, result.ticket.id
    assert_equal 3, ticket.messages.count
  end

  test "References threads onto the existing ticket when In-Reply-To is absent" do
    ticket = ingest(:new_ticket).ticket

    result = ingest(:reply_references_only)

    assert_equal ticket.id, result.ticket.id
    # The unknown id earlier in the chain is skipped rather than fatal.
    assert_equal "<CAFdeadbeef01@mail.example.com>", result.message.message_id
  end

  test "the [#id] subject tag threads when no headers survive" do
    ticket = ingest(:new_ticket).ticket

    result = ingest(:subject_tag_only, ticket_id: ticket.id)

    assert_equal ticket.id, result.ticket.id
  end

  test "a subject tag from a different customer opens a new ticket instead of joining" do
    ticket = ingest(:new_ticket).ticket

    result = ingest(:subject_tag_wrong_customer, ticket_id: ticket.id)

    assert result.created?
    refute_equal ticket.id, result.ticket.id
    assert_equal "mallory@elsewhere.test", result.ticket.customer.email
  end

  test "an unrelated message opens its own ticket" do
    ingest(:new_ticket)

    result = ingest(:html_only)

    assert_equal 2, Ticket.count
    assert_equal "Cannot log in to the portal", result.ticket.subject
  end

  test "inbound reopens a closed ticket and touches last_activity_at" do
    ticket = ingest(:new_ticket).ticket
    ticket.update!(state: "closed", last_activity_at: 1.week.ago)

    result = ingest(:reply_references_only)

    ticket.reload
    assert_equal "open", ticket.state
    # Against the message that arrived, not against the wall clock. The .eml
    # fixtures carry fixed Date: headers, so any window measured from `now`
    # passes until the day the fixtures fall out of it and then fails forever.
    assert_equal result.message.sent_at, ticket.last_activity_at
  end

  # --- rejection -----------------------------------------------------------

  test "rejects before creating anything" do
    {
      auto_reply: /auto-submitted/,
      bulk_precedence: /precedence/,
      bounce: /return-path|delivery-status/,
      mailing_list: /mailing list/
    }.each do |fixture, reason_pattern|
      assert_no_difference ["Message.count", "Ticket.count", "Customer.count"], "#{fixture} should be rejected" do
        result = ingest(fixture)

        assert result.rejected?, "expected #{fixture} to be rejected, got #{result.outcome}"
        assert_match reason_pattern, result.reason
      end
    end
  end

  test "rejects Spool's own outbound message echoed back" do
    ticket = ingest(:new_ticket).ticket
    outbound_reply(ticket, "<spool-outbound-0001@spool.test>")

    echoed = raw(:new_ticket)
      .sub("<CAF1a2b3c4d5@mail.example.com>", "<spool-outbound-0001@spool.test>")

    assert_no_difference "Message.count" do
      result = Ingest::Inbound.ingest(echoed)

      assert result.rejected?
      assert_match(/own outbound/, result.reason)
    end
  end

  # --- MIME splitting ------------------------------------------------------

  test "splits text, html and binary parts" do
    message = ingest(:with_attachments).message.reload

    assert_includes message.body_text, "photo of the printer on fire"
    assert_includes message.body_html, "<img src=\"cid:logo-001\">"
    assert_equal 2, message.attachments.count
  end

  test "an inline part keeps its content_id so cid: references resolve" do
    message = ingest(:with_attachments).message

    inline = message.message_attachments.find_by(filename: "logo.png")
    assert_equal "logo-001", inline.content_id
    assert inline.inline?

    regular = message.message_attachments.find_by(filename: "fire.png")
    assert_nil regular.content_id
    refute regular.inline?
  end

  test "identical attachment bytes are stored once and shared" do
    ingest(:with_attachments)

    assert_no_difference "Attachment.count" do
      ingest(:duplicate_attachment)
    end

    # Same blob, different filename per message — which is the point.
    assert_equal 2, MessageAttachment.where(filename: %w[logo.png image001.png]).count
    assert_equal 1, MessageAttachment.where(filename: %w[logo.png image001.png])
      .distinct.count(:attachment_id)
  end

  test "attachment bytes survive the round trip" do
    message = ingest(:with_attachments).message
    attachment = message.message_attachments.find_by(filename: "fire.png").attachment

    assert_equal "image/png", attachment.content_type
    assert attachment.bytes.start_with?("\x89PNG".b)
    assert_equal attachment.bytes.bytesize, attachment.byte_size
  end

  test "an html-only message still gets a searchable plain-text excerpt" do
    message = ingest(:html_only).message

    assert_nil message.body_text
    assert_includes message.body_html, "<b>cannot</b>"
    assert_includes message.body_excerpt, "cannot log in to the portal"
    # Entities decoded, tags gone.
    assert_includes message.body_excerpt, '"account locked"'
    refute_includes message.body_excerpt, "<p>"
    # <head>, <title> and <style> contents are not prose and must not leak in.
    refute_includes message.body_excerpt, "CLIENT-SPECIFIC STYLES"
    refute_includes message.body_excerpt, "Example Corp Webmail"
  end

  test "Reply-To wins over From: a form mail belongs to the human, not the mailer" do
    result = ingest(:form_reply_to)

    assert result.created?
    assert_equal "hugh@example.org", result.ticket.customer.email
    assert_equal "hugh@example.org", result.message.from_email
    # The From display name ("Example Shop") must not stick to the human.
    assert_nil result.message.from_name
    # The real From header is still recoverable.
    assert_includes result.message.headers, "From: Example Shop <admin@mg.example-shop.com>"
  end

  test "X-Spool-Meta-* headers surface as structured metadata" do
    message = ingest(:form_reply_to).message.reload

    meta = message.spool_meta
    assert_equal "9780375703768", meta["product"]
    assert_equal "https://booko.au/9780375703768/", meta["product-url"]
    assert_equal "au", meta["region"]
    assert_equal "iOS 17.5", meta["platform"]
    # A folded header value is unfolded, not truncated at the line break.
    assert_includes meta["agent"], "AppleWebKit/605.1.15"
    # Nothing else leaks in under meta keys.
    assert_equal %w[ip agent platform access-type user product product-url region].sort, meta.keys.sort
  end

  test "a message without meta headers has empty spool_meta" do
    assert_equal({}, ingest(:new_ticket).message.reload.spool_meta)
  end

  test "a non-UTF-8 charset is transcoded rather than raising" do
    message = ingest(:latin1_charset).message.reload

    assert_equal Encoding::UTF_8, message.body_text.encoding
    assert_includes message.body_text, "problème"
    assert_includes message.subject, "Problème de facturation"
    assert_equal "René Descartes", message.from_name
  end

  # --- excerpt -------------------------------------------------------------

  test "body_excerpt strips quoted history but the full body is kept" do
    ticket = ingest(:new_ticket).ticket
    outbound_reply(ticket, "<spool-outbound-0001@spool.test>")

    message = ingest(:reply_in_reply_to).message.reload

    assert_includes message.body_excerpt, "still under warranty"
    refute_includes message.body_excerpt, "Could you confirm the purchase date"

    # The quoted text is still there in the stored body — customers top-post
    # inside quotes and the original has to survive.
    assert_includes message.body_text, "Could you confirm the purchase date"
  end

  test "raw_size records the uncompressed size of what the blobs hold" do
    message = ingest(:new_ticket).message.reload

    assert_equal message.headers.bytesize + message.body.bytesize, message.raw_size
    assert_operator message.raw_size, :>, 0
  end

  # --- search --------------------------------------------------------------

  test "ingested messages are findable through FTS5" do
    ingest(:new_ticket)
    ingest(:html_only)

    assert_equal ["<CAF1a2b3c4d5@mail.example.com>"], Message.search("warranty").pluck(:message_id)
    assert_equal ["<CAFhtmlonly001@mail.example.com>"], Message.search("portal").pluck(:message_id)
    assert_empty Message.search("nothing matches this")
  end

  private

  def raw(fixture)
    Rails.root.join("test/fixtures/files/emails/#{fixture}.eml").read
  end

  def ingest(fixture, ticket_id: nil)
    body = raw(fixture)
    body = body.sub("TICKET_ID", ticket_id.to_s) if ticket_id
    Ingest::Inbound.ingest(body, source: "test")
  end

  # Stands in for the outbound path (milestone 5), which doesn't exist yet: the
  # threading tests need a message with a Spool-issued Message-ID for a customer
  # reply to point back at.
  def outbound_reply(ticket, message_id)
    Message.create!(
      ticket: ticket,
      direction: "outbound",
      message_id: message_id,
      subject: "Re: #{ticket.subject}",
      sent_at: Time.current,
      body: JSON.generate({"text" => "Could you confirm the purchase date?", "html" => nil})
    )
  end
end
