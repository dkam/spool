# frozen_string_literal: true

module Ingest
  # Splits a parsed message into the three things Spool stores: the header
  # block, the body text, and the binary parts.
  #
  # There is deliberately no path back: Spool does not keep raw MIME and cannot
  # rebuild it byte-for-byte. Reconstructing exact MIME from parsed parts is
  # unwinnable (boundary strings, transfer-encoding choices, header folding all
  # vary), and the upstream mailbox keeps a copy if forensics are ever needed.
  # See docs/ingest.md.
  class MimeSplitter
    Part = Struct.new(:bytes, :content_type, :filename, :content_id, keyword_init: true)

    Result = Struct.new(:headers, :body_document, :text, :html, :attachments, keyword_init: true)

    # A single part larger than this is stored as an attachment rather than
    # inlined as body text, whatever it claims to be. Guards against a runaway
    # text/plain part becoming a body nobody can render.
    MAX_INLINE_BODY_BYTES = 2 * 1024 * 1024

    def initialize(mail)
      @mail = mail
    end

    def call
      text, html, attachments = walk(@mail)

      Result.new(
        headers: @mail.header.raw_source.to_s,
        body_document: body_document(text, html),
        text: text,
        html: html,
        attachments: attachments
      )
    end

    private

    # body_blob holds a JSON document rather than a bare string, because a
    # message legitimately has both a text/plain and a text/html rendering and
    # discarding either one loses something: the HTML is what the customer
    # actually saw, the plain text is what quotes and searches cleanly. JSON is
    # the cheapest container that keeps them distinguishable, and it compresses
    # away to nearly nothing next to the body text itself.
    #
    # Every row is written by this method, so the format is guaranteed —
    # Message#body_document parses it without guessing.
    def body_document(text, html)
      JSON.generate({"text" => text, "html" => html})
    end

    # Depth-first walk. Anything with a filename or a Content-Disposition of
    # attachment/inline becomes an attachment; text/plain and text/html parts
    # become body text; everything else (application/*, image/* without a
    # disposition) becomes an attachment too, since it certainly isn't body.
    def walk(part, text = nil, html = nil, attachments = [])
      if part.multipart?
        part.parts.each { |child| text, html, attachments = walk(child, text, html, attachments) }
        return [text, html, attachments]
      end

      if attachment_part?(part)
        attachments << build_attachment(part)
        return [text, html, attachments]
      end

      content_type = part.mime_type.to_s.downcase
      decoded = decode_text(part)

      if decoded.bytesize > MAX_INLINE_BODY_BYTES
        attachments << build_attachment(part)
        return [text, html, attachments]
      end

      case content_type
      when "text/plain"
        # Concatenated rather than replaced: a message can carry more than one
        # text part (a forwarded chain, a signature block appended as its own
        # part), and dropping all but the last would silently lose content.
        text = [text, decoded].compact_blank.join("\n\n")
      when "text/html"
        html = [html, decoded].compact_blank.join("\n")
      else
        attachments << build_attachment(part)
      end

      [text, html, attachments]
    end

    def attachment_part?(part)
      return true if part.attachment?

      disposition = part.content_disposition.to_s.downcase
      return true if disposition.start_with?("attachment")

      # An inline part with a Content-ID is a cid: image in an HTML body, not
      # body text.
      return true if disposition.start_with?("inline") && part.content_id.present?

      false
    end

    def build_attachment(part)
      Part.new(
        bytes: part.body.decoded,
        content_type: part.mime_type.presence || "application/octet-stream",
        filename: part.filename.presence,
        # The mail gem hands back the Content-ID with angle brackets; strip them
        # so the value matches what a `cid:` URL in the HTML body references.
        content_id: part.content_id&.to_s&.delete("<>").presence
      )
    end

    # `decoded` undoes the transfer encoding (base64, quoted-printable) but
    # hands back bytes still in the part's own charset. Transcode to UTF-8,
    # replacing anything that doesn't map: a helpdesk should render a mojibake
    # character rather than raise while displaying a customer's email.
    def decode_text(part)
      raw = part.body.decoded
      charset = part.charset.presence || "UTF-8"

      raw.force_encoding(charset).encode(
        Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�"
      )
    rescue ArgumentError, TypeError, Encoding::ConverterNotFoundError
      # An unknown or lying charset label. Treat it as UTF-8 and scrub.
      raw.to_s.dup.force_encoding(Encoding::UTF_8).scrub("�")
    rescue => e
      Rails.logger.warn "[MimeSplitter] undecodable part (#{e.class}): treating as empty"
      ""
    end
  end
end
