# frozen_string_literal: true

module Outbound
  # The slice of Mailgun's API Spool needs: hand over a fully-built RFC822
  # message and a recipient, get back the id Mailgun assigned. It knows nothing
  # about tickets or Message rows — Outbound::Delivery holds all of that.
  #
  # The .mime endpoint rather than the parameter one, deliberately: Spool has
  # already built the exact message it wants sent — Message-ID, In-Reply-To,
  # References, Date — and a parameter-assembled send would have Mailgun
  # generate its own Message-ID, breaking both threading in the customer's
  # client and LoopGuard's recognition of our mail echoed back.
  class Mailgun
    DEFAULT_API_BASE = "https://api.mailgun.net"

    def initialize(api_key:, domain:, api_base: nil, http: Http.new)
      @api_key = api_key
      @domain = domain
      @api_base = (api_base.presence || DEFAULT_API_BASE).chomp("/")
      @http = http
    end

    # `to` is the envelope recipient; the headers inside `mime` are what the
    # customer sees. Returns Mailgun's queue id, useful only for the log.
    def deliver_mime(to:, mime:)
      body = @http.post_form(
        "#{@api_base}/v3/#{@domain}/messages.mime",
        {
          "to" => to,
          "message" => {content: mime, filename: "message.mime", content_type: "message/rfc822"}
        },
        basic_auth: ["api", @api_key]
      )

      JSON.parse(body)["id"]
    rescue JSON::ParserError
      # A 2xx with an unparseable body — Mailgun took the message; only the
      # queue id is lost, and it was only ever for the log line.
      nil
    end
  end
end
