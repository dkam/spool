# frozen_string_literal: true

module Jmap
  # A JMAP client covering the slice Spool needs: the session handshake, batched
  # method calls, and blob download. It knows nothing about tickets, tubes or
  # folders — Jmap::Poller holds all of that. The split is the point: this class
  # is the part that could become a gem, and it stays honest by never mentioning
  # Spool.
  #
  # JMAP is JSON over HTTPS, so there is no protocol library here and none is
  # needed. The one published Ruby JMAP gem had a single release in 2021; the
  # other is unreleased. Both are more surface than this, less maintained, and
  # would sit in the critical path of the only thing that puts mail into Spool.
  #
  # Spec: RFC 8620 (core) and RFC 8621 (mail).
  class Client
    CORE = "urn:ietf:params:jmap:core"
    MAIL = "urn:ietf:params:jmap:mail"

    # Sent on every request. The server rejects calls whose capability isn't
    # declared here, and core is mandatory alongside anything else.
    USING = [CORE, MAIL].freeze

    DEFAULT_SESSION_URL = "https://api.fastmail.com/jmap/session"

    class Error < StandardError; end

    # A method-level failure. JMAP returns these in-band as an "error" response
    # with a 200 status, so nothing in Jmap::Http will have noticed.
    class MethodError < Error
      attr_reader :type, :call_id

      def initialize(type, call_id, description = nil)
        @type = type
        @call_id = call_id
        super([%(JMAP method call "#{call_id}" failed: #{type}), description].compact.join(" — "))
      end
    end

    def initialize(token:, session_url: nil, http: Http.new)
      @token = token
      @session_url = session_url.presence || DEFAULT_SESSION_URL
      @http = http
    end

    # The session resource, fetched once per instance.
    #
    # Everything downstream reads its URLs from here rather than building them,
    # because Fastmail pins accounts to a region: a live session hands back
    # `https://phl.api.fastmail.com/...`, not the `api.fastmail.com` you asked.
    # Hardcoding the latter works right up until an account is moved, and the
    # failure lands on the only path that delivers mail. The poller is
    # short-lived, so "once per instance" is also "once per poll" — cheap, and it
    # picks up a region change without a restart.
    def session
      @session ||= JSON.parse(@http.get(@session_url, auth_headers))
    end

    def account_id
      session.dig("primaryAccounts", MAIL) or
        raise Error, "session has no primary account for #{MAIL} — does the token carry the mail scope?"
    end

    def api_url
      session.fetch("apiUrl")
    end

    # Whether this credential may only read. A Fastmail API token can be issued
    # read-only per scope, and the session reports the consequence here (RFC 8620
    # §1.6.2) rather than making you discover it at the first write.
    def read_only?
      !!session.dig("accounts", account_id, "isReadOnly")
    end

    # Present in the session whether or not you use it. Recorded here so the
    # eventual push path has somewhere obvious to read it from; nothing calls it
    # yet. See docs/ingest.md on why the poll stays the durable path.
    def event_source_url
      session["eventSourceUrl"]
    end

    # Issue one or more method calls in a single HTTP request and return their
    # responses in order.
    #
    # Batching matters more than it looks: Fastmail advertises
    # maxCallsInRequest: 50, and back-references let one request do
    # "query, then fetch what the query found" without a round trip in between.
    # A whole poll cycle is one request plus the blob downloads.
    #
    # Each call is [method_name, arguments, call_id]. Returns the arguments of
    # each response, keyed by call id.
    def call(*method_calls)
      body = @http.post_json(api_url, {using: USING, methodCalls: method_calls}, auth_headers)
      responses = JSON.parse(body).fetch("methodResponses")

      responses.to_h do |name, arguments, call_id|
        raise MethodError.new(arguments["type"], call_id, arguments["description"]) if name == "error"

        [call_id, arguments]
      end
    end

    # A result reference, for chaining one call's output into the next.
    #
    # `path` is a JSON Pointer into the referenced response. RFC 8621's own
    # Email/query → Email/get example uses "/ids", the whole array; some
    # documentation writes "/ids/*", which maps over it. Both resolve to the same
    # list of ids here — this is the spec's form.
    def self.reference(result_of, name, path)
      {resultOf: result_of, name: name, path: path}
    end

    # Fetch a blob's bytes. For an Email's own blobId that is the complete
    # RFC822 message, which is exactly what Ingest::Inbound.ingest wants.
    #
    # `type` only sets the Content-Type the server responds with; octet-stream
    # keeps it from deciding to be helpful about a message body it thinks it
    # understands.
    def download(blob_id, type: "application/octet-stream", name: "message.eml")
      url = expand_download_url(blob_id, type, name)
      @http.get(url, auth_headers)
    end

    private

    # The session's downloadUrl is a template with {accountId}, {blobId}, {type}
    # and {name} placeholders, per RFC 8620.
    def expand_download_url(blob_id, type, name)
      template = session.fetch("downloadUrl")

      {
        "accountId" => account_id,
        "blobId" => blob_id,
        "type" => type,
        "name" => name
      }.reduce(template) do |url, (key, value)|
        url.gsub("{#{key}}", CGI.escape(value.to_s))
      end
    end

    def auth_headers
      {"Authorization" => "Bearer #{@token}", "Accept" => "application/json"}
    end
  end
end
