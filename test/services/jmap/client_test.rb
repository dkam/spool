# frozen_string_literal: true

require "test_helper"
require_relative "../../support/fake_jmap_server"

# The protocol layer on its own. These are the claims the poller then gets to
# take for granted.
class Jmap::ClientTest < ActiveSupport::TestCase
  setup do
    @server = FakeJmapServer.new
    @client = Jmap::Client.new(
      token: "test-token",
      session_url: FakeJmapServer::SESSION_URL,
      http: @server
    )
  end

  # --- the session is the source of every URL ------------------------------

  test "reads the account id from primaryAccounts" do
    assert_equal FakeJmapServer::ACCOUNT_ID, @client.account_id
  end

  test "calls the api url the session gave, not the host the session lives on" do
    # Fastmail pins accounts to a region: you ask api.fastmail.com and it hands
    # back phl.api.fastmail.com. A client that built URLs from the configured
    # host would work until an account moved.
    @client.call(["Mailbox/get", {accountId: @client.account_id, ids: nil}, "m"])

    assert_not_equal URI.parse(FakeJmapServer::SESSION_URL).host,
      URI.parse(FakeJmapServer::API_URL).host
    assert_equal 1, @server.requests.size
  end

  test "downloads from the session's templated url" do
    id = @server.add_email("raw bytes here", @server.add_mailbox("Spool"))
    blob_id = @client
      .call(["Email/get", {accountId: @client.account_id, ids: [id], properties: ["blobId"]}, "g"])
      .fetch("g").fetch("list").sole.fetch("blobId")

    assert_equal "raw bytes here", @client.download(blob_id)
  end

  test "reports whether the credential may write, without trying a write" do
    # Spool wants a read-only token, so this is how a deployment proves it got
    # one. The session already carries the answer (RFC 8620 §1.6.2), which beats
    # discovering it at the first attempted write.
    assert @client.read_only?

    @server.read_only = false
    assert_not Jmap::Client.new(
      token: "test-token",
      session_url: FakeJmapServer::SESSION_URL,
      http: @server
    ).read_only?
  end

  test "exposes the event source url for the eventual push path" do
    assert_equal FakeJmapServer::EVENT_SOURCE_URL, @client.event_source_url
  end

  test "fetches the session once, however many calls follow" do
    3.times { @client.call(["Mailbox/get", {accountId: @client.account_id, ids: nil}, "m"]) }

    assert_equal 1, @server.session_fetches
    assert_equal 3, @server.requests.size
  end

  # --- batching ------------------------------------------------------------

  test "returns each response keyed by its call id" do
    spool = @server.add_mailbox("Spool")
    @server.add_email("a message", spool)

    responses = @client.call(
      ["Mailbox/get", {accountId: @client.account_id, ids: nil}, "boxes"],
      ["Email/query", {
        accountId: @client.account_id,
        filter: {inMailbox: spool},
        sort: [{property: "receivedAt", isAscending: true}],
        limit: 10
      }, "query"]
    )

    assert_equal %w[boxes query], responses.keys
    assert_equal 1, responses.fetch("query").fetch("ids").size
  end

  test "a back-reference feeds one call's ids into the next" do
    spool = @server.add_mailbox("Spool")
    @server.add_email("a message", spool)

    responses = @client.call(
      ["Email/query", {
        accountId: @client.account_id,
        filter: {inMailbox: spool},
        sort: [{property: "receivedAt", isAscending: true}],
        limit: 10
      }, "query"],
      ["Email/get", {
        "accountId" => @client.account_id,
        "#ids" => Jmap::Client.reference("query", "Email/query", "/ids"),
        "properties" => ["id", "blobId"]
      }, "get"]
    )

    assert_equal 1, responses.fetch("get").fetch("list").size
    assert_equal 1, @server.requests.size, "the chain must not cost a second round trip"
  end

  # --- errors --------------------------------------------------------------

  test "an in-band method error raises rather than returning quietly" do
    # JMAP reports method failures as an "error" response with a 200 status, so
    # nothing in the transport will have noticed one.
    @server.failing_method = "Email/get"

    error = assert_raises(Jmap::Client::MethodError) do
      @client.call(["Email/get", {accountId: @client.account_id, ids: ["x"], properties: ["id"]}, "g"])
    end

    assert_equal "serverFail", error.type
    assert_equal "g", error.call_id
  end

  test "a bad token raises Unauthorized" do
    client = Jmap::Client.new(
      token: "wrong",
      session_url: FakeJmapServer::SESSION_URL,
      http: @server
    )

    assert_raises(Jmap::Http::Unauthorized) { client.account_id }
  end
end
