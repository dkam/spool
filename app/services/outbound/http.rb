# frozen_string_literal: true

require "net/http"

module Outbound
  # The transport seam for outbound delivery, and the only thing in Outbound::
  # that touches a socket — Outbound::Mailgun takes one of these, and the tests
  # pass a fake instead, exactly the Jmap::Http arrangement.
  #
  # One method, because Mailgun's send endpoint is one shape: a multipart form
  # POST under HTTP basic auth. A form value given as {content:, filename:,
  # content_type:} is sent as a file part, which is how the raw MIME message
  # travels.
  class Http
    class Error < StandardError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        @status = status
        @body = body
        super(message)
      end
    end

    # The provider looked at the request and said no — bad API key, unknown
    # sending domain, a recipient it refuses. Retrying the same request buys
    # nothing, so the consumer buries on this rather than cycling it. A 429 is
    # deliberately NOT one of these: rate limiting is the one 4xx that a
    # released job outlives.
    class Rejected < Error; end

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 30

    def post_form(url, fields, basic_auth: nil)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(*basic_auth) if basic_auth
      request.set_form(form_data(fields), "multipart/form-data")

      response = Net::HTTP.start(
        uri.hostname, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) { |http| http.request(request) }

      case response
      when Net::HTTPSuccess
        response.body.to_s
      when Net::HTTPTooManyRequests
        raise Error.new("rate limited (429)", status: 429, body: response.body)
      when Net::HTTPClientError
        raise Rejected.new(
          "request rejected: #{response.code} #{response.message} — #{response.body.to_s.truncate(200)}",
          status: response.code.to_i, body: response.body
        )
      else
        raise Error.new(
          "request failed: #{response.code} #{response.message}",
          status: response.code.to_i, body: response.body
        )
      end
    end

    private

    def form_data(fields)
      fields.map do |name, value|
        if value.is_a?(Hash)
          [name.to_s, StringIO.new(value.fetch(:content)),
            {filename: value[:filename], content_type: value[:content_type]}]
        else
          [name.to_s, value.to_s]
        end
      end
    end
  end
end
