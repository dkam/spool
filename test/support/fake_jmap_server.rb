# frozen_string_literal: true

# A small in-memory JMAP server, standing in for Jmap::Http.
#
# It models state rather than replaying canned responses, so a second poll
# genuinely re-queries the same folder and has to be filtered out by the cursor
# rather than by a fixture that happens to be empty. That is the behaviour worth
# testing — a fixture-shaped fake would assert only that we can parse our own
# JSON.
#
# Its URLs deliberately disagree with each other: the session lives on
# api.example.com and hands back phl.api.example.com for everything else, which
# is the Fastmail regional-pinning shape. A client that hardcoded a host instead
# of reading the session would fail here, which is the point.
class FakeJmapServer
  ACCOUNT_ID = "u6280415d"
  SESSION_URL = "https://api.example.com/jmap/session"
  API_URL = "https://phl.api.example.com/jmap/api/"
  DOWNLOAD_URL = "https://phl.api.example.com/jmap/download/{accountId}/{blobId}/{name}?type={type}"
  EVENT_SOURCE_URL = "https://phl.api.example.com/jmap/event/?types={types}&closeafter={closeafter}&ping={ping}"

  # Every methodCalls array the client sent, in order. Lets a test assert that a
  # poll was one HTTP request rather than several.
  attr_reader :requests

  # How many times the session resource was fetched. The client is supposed to
  # do that once per instance.
  attr_reader :session_fetches

  # Set to true to fail every download, or to a single blob id (see #blob_of) to
  # fail just that one. The second form is what exercises "a message behind a
  # failure still gets through".
  attr_accessor :download_error

  # Set to a method name to make it fail in-band, the way JMAP reports method
  # errors: an "error" response with a 200 status.
  attr_accessor :failing_method

  # Stands in for a read-only API token, which Fastmail reports on the account.
  # Defaults to true because that is the token Spool is meant to be given; the
  # writable case is the anomaly, and a test that wants it says so.
  attr_accessor :read_only

  # Emails with no explicit receivedAt are spaced a second apart from here, so a
  # test only shares a timestamp when it means to.
  EPOCH = Time.utc(2026, 8, 12)

  def initialize(token: "test-token")
    @token = token
    @mailboxes = []
    @emails = {}
    @blobs = {}
    @requests = []
    @session_fetches = 0
    @sequence = 0
    @read_only = true
  end

  # --- fixture building ----------------------------------------------------

  def add_mailbox(name, parent: nil)
    id = "mb#{@sequence += 1}"
    @mailboxes << {"id" => id, "name" => name, "parentId" => parent}
    id
  end

  def add_email(raw, mailbox_id, received_at: nil)
    id = "em#{@sequence += 1}"
    blob_id = "blob#{@sequence}"
    @blobs[blob_id] = raw.b
    @emails[id] = {
      "id" => id,
      "blobId" => blob_id,
      "receivedAt" => received_at || (EPOCH + @sequence).iso8601,
      "mailboxIds" => {mailbox_id => true}
    }
    id
  end

  def ids_in(mailbox_id)
    @emails.values.select { |e| e["mailboxIds"][mailbox_id] }.map { |e| e["id"] }
  end

  # For pointing download_error at one message.
  def blob_of(email_id)
    @emails.fetch(email_id).fetch("blobId")
  end

  # --- the Jmap::Http interface --------------------------------------------

  def get(url, headers = {})
    authorize!(headers)

    if url == SESSION_URL
      @session_fetches += 1
      return JSON.generate(session)
    end

    blob_id = url[%r{/download/[^/]+/([^/?]+)}, 1]
    raise Jmap::Http::Error.new("no such blob", status: 404) unless @blobs.key?(blob_id)
    raise Jmap::Http::Error.new("boom", status: 500) if download_error == true || download_error == blob_id

    @blobs.fetch(blob_id)
  end

  def post_json(url, payload, headers = {})
    authorize!(headers)
    raise "posted to #{url}, expected #{API_URL}" unless url == API_URL

    # Round-trip through JSON so the fake sees exactly what the wire would,
    # symbol keys and all. Without this the tests would quietly accept a payload
    # that only works because it never got serialised.
    method_calls = JSON.parse(JSON.generate(payload)).fetch("methodCalls")
    @requests << method_calls

    responses = []
    method_calls.each do |name, arguments, call_id|
      if name == failing_method
        responses << ["error", {"type" => "serverFail", "description" => "fake failure"}, call_id]
        next
      end

      responses << [name, dispatch(name, resolve_references(arguments, responses)), call_id]
    end

    JSON.generate({methodResponses: responses, sessionState: "abc"})
  end

  private

  def session
    {
      "capabilities" => {Jmap::Client::CORE => {}, Jmap::Client::MAIL => {}},
      "accounts" => {ACCOUNT_ID => {"name" => "support@example.com", "isReadOnly" => !!read_only}},
      "primaryAccounts" => {Jmap::Client::CORE => ACCOUNT_ID, Jmap::Client::MAIL => ACCOUNT_ID},
      "apiUrl" => API_URL,
      "downloadUrl" => DOWNLOAD_URL,
      "eventSourceUrl" => EVENT_SOURCE_URL
    }
  end

  def authorize!(headers)
    return if headers["Authorization"] == "Bearer #{@token}"

    raise Jmap::Http::Unauthorized.new("bad token", status: 401)
  end

  # Back-references: {"#ids" => {resultOf:, name:, path:}} becomes "ids".
  def resolve_references(arguments, responses)
    arguments.each_with_object({}) do |(key, value), resolved|
      key = key.to_s
      unless key.start_with?("#")
        resolved[key] = value
        next
      end

      reference = value.transform_keys(&:to_s)
      _, response_arguments, = responses.find { |_, _, call_id| call_id == reference.fetch("resultOf") }
      pointer = reference.fetch("path").delete_suffix("/*").delete_prefix("/")
      resolved[key.delete_prefix("#")] = response_arguments.fetch(pointer)
    end
  end

  def dispatch(name, arguments)
    case name
    when "Mailbox/get" then {"list" => @mailboxes}
    when "Email/query" then email_query(arguments)
    when "Email/get" then email_get(arguments)
    # Deliberately no Email/set. Spool only ever reads the mailbox, and a fake
    # that could write would let a regression reintroducing a write pass here
    # and fail against a read-only token in production.
    else raise "FakeJmapServer got an unexpected method call: #{name}"
    end
  end

  def email_query(arguments)
    filter = arguments.fetch("filter")
    matching = @emails.values.select { |e| e["mailboxIds"][filter.fetch("inMailbox")] }

    # RFC 8621: `after` matches receivedAt *on or after* the given date-time.
    # Inclusive, which is exactly why the poller carries ids alongside the
    # timestamp — get this wrong here and the test suite stops proving it.
    # String comparison is sound because these are all Z-suffixed ISO 8601.
    after = filter["after"]
    matching = matching.select { |e| e["receivedAt"] >= after } if after

    ascending = arguments.fetch("sort").first.fetch("isAscending")
    matching = matching.sort_by { |e| e["receivedAt"] }
    matching = matching.reverse unless ascending

    {"ids" => matching.first(arguments.fetch("limit")).map { |e| e["id"] }}
  end

  def email_get(arguments)
    properties = arguments.fetch("properties").map(&:to_s)
    list = arguments.fetch("ids").filter_map do |id|
      @emails[id]&.slice(*properties)
    end

    {"list" => list}
  end
end
