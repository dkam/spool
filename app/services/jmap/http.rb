# frozen_string_literal: true

require "net/http"

module Jmap
  # The transport seam, and deliberately the only thing in Jmap:: that touches a
  # socket. Jmap::Client takes one of these; the tests pass a fake instead, which
  # is why the suite needs no HTTP stubbing library.
  #
  # It stays dumb on purpose: bytes in, bytes out, no JSON parsing. The blob
  # download returns raw RFC822 — 8-bit MIME that must reach Ingest::Inbound
  # byte-for-byte — so a transport that helpfully parsed or transcoded responses
  # would corrupt exactly the thing this exists to fetch.
  class Http
    class Error < StandardError
      attr_reader :status, :body

      def initialize(message, status: nil, body: nil)
        @status = status
        @body = body
        super(message)
      end
    end

    # Separated because the recovery differs: a 401 means the token was revoked
    # or the scopes changed, and no amount of retrying fixes it. The poller logs
    # it loudly rather than cycling.
    class Unauthorized < Error; end

    OPEN_TIMEOUT = 5

    # Generous, because a blob download of a large message with attachments is on
    # the same clock as a small API call. Still well inside the tube's 120s TTR.
    READ_TIMEOUT = 30

    def get(url, headers = {})
      perform(Net::HTTP::Get.new(URI.parse(url)), headers)
    end

    def post_json(url, payload, headers = {})
      request = Net::HTTP::Post.new(URI.parse(url))
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(payload)
      perform(request, headers)
    end

    private

    def perform(request, headers)
      headers.each { |name, value| request[name] = value }
      uri = request.uri

      response = Net::HTTP.start(
        uri.hostname, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) { |http| http.request(request) }

      case response
      when Net::HTTPSuccess
        # .b because this may be an RFC822 blob. Net::HTTP hands back a String
        # tagged with whatever charset it inferred from the response headers;
        # binary is the only honest encoding for MIME bytes.
        response.body.to_s.b
      when Net::HTTPUnauthorized, Net::HTTPForbidden
        raise Unauthorized.new(
          "JMAP rejected the token (#{response.code}) — check it exists and carries the mail scope",
          status: response.code.to_i, body: response.body
        )
      else
        raise Error.new(
          "JMAP request failed: #{response.code} #{response.message}",
          status: response.code.to_i, body: response.body
        )
      end
    end
  end
end
