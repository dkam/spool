# frozen_string_literal: true

require "test_helper"

# POST /mcp: the HTTP edge of the MCP server. The tools themselves are covered
# in test/mcp; what is this file's is who gets in, who a write is attributed
# to, and that the answers are the shapes an MCP client expects.
class McpEndpointTest < ActionDispatch::IntegrationTest
  OIDC = {
    "OIDC_CLIENT_ID" => "spool",
    "OIDC_CLIENT_SECRET" => "secret",
    "OIDC_DISCOVERY_URL" => "https://clinch.example.com"
  }.freeze

  setup do
    @agent = Agent.create!(oidc_sub: "agent-1", email: "sam@spool.test", name: "Sam")
    @other = Agent.create!(oidc_sub: "agent-2", email: "lee@spool.test", name: "Lee")
    @token = McpToken.issue!(@agent)

    @customer = Customer.create!(email: "dana@fieldworks.co", name: "Dana Whitmore")
    @ticket = Ticket.create!(customer: @customer, subject: "Outbox stuck", state: "open",
      last_activity_at: 10.minutes.ago)
  end

  def rpc(method, params = nil, id: 1, token: @token)
    frame = {jsonrpc: "2.0", id: id, method: method, params: params}.compact
    headers = {"Accept" => "application/json, text/event-stream"}
    headers["Authorization"] = "Bearer #{token}" if token
    post mcp_path, params: frame.to_json, headers: headers.merge("Content-Type" => "application/json")
  end

  def result = response.parsed_body.fetch("result")

  def tool_text = result.dig("content", 0, "text")

  # --- Who gets in ----------------------------------------------------------

  # The test environment runs in open mode, where the UI needs no sign-in.
  # The endpoint must not inherit that: open mode is "no IdP yet", not "no
  # authentication", and /mcp can send mail to customers.
  test "no token is refused, even in open mode" do
    rpc "tools/list", token: nil

    assert_response :unauthorized
    assert_match(/\ABearer/, response.headers["WWW-Authenticate"])
    assert_equal(-32001, response.parsed_body.dig("error", "code"))
  end

  test "an unknown token is refused" do
    rpc "tools/list", token: "spool_#{"x" * 43}"

    assert_response :unauthorized
  end

  test "a revoked token is refused" do
    @agent.mcp_token.destroy!

    rpc "tools/list"

    assert_response :unauthorized
  end

  test "a token whose agent left the allowlist is refused" do
    with_env(OIDC.merge("SPOOL_ALLOWED_USERS" => "lee@spool.test")) do
      rpc "tools/list"

      assert_response :unauthorized
    end
  end

  test "a token works under enforcing auth for an agent on the allowlist" do
    with_env(OIDC.merge("SPOOL_ALLOWED_USERS" => "sam@spool.test")) do
      rpc "tools/list"

      assert_response :success
    end
  end

  # Half-configured auth serves nothing in the UI; a token must not be the
  # way around that, since the allowlist check it relies on is off too.
  test "half-configured auth refuses tokens as well" do
    with_env("OIDC_CLIENT_ID" => "spool", "OIDC_CLIENT_SECRET" => nil, "OIDC_DISCOVERY_URL" => nil) do
      rpc "tools/list"

      assert_response :service_unavailable
    end
  end

  # --- Speaking MCP ---------------------------------------------------------

  test "initialize names the server" do
    rpc "initialize", {protocolVersion: "2025-06-18", capabilities: {}, clientInfo: {name: "test", version: "1"}}

    assert_response :success
    assert_equal "spool", result.dig("serverInfo", "name")
  end

  test "tools/list offers the tools" do
    rpc "tools/list"

    names = result.fetch("tools").map { |tool| tool["name"] }
    assert_includes names, "list_tickets"
    assert_includes names, "reply_to_ticket"
  end

  test "a tool call reads the helpdesk" do
    rpc "tools/call", {name: "list_tickets", arguments: {}}

    assert_response :success
    ids = JSON.parse(tool_text).fetch("tickets").map { |t| t["id"] }
    assert_equal [@ticket.id], ids
  end

  # A notification has no id and gets no answer; answering anyway is a
  # protocol violation.
  test "a notification is accepted with nothing to say" do
    post mcp_path,
      params: {jsonrpc: "2.0", method: "notifications/initialized"}.to_json,
      headers: {"Authorization" => "Bearer #{@token}", "Content-Type" => "application/json"}

    assert_response :accepted
    assert_empty response.body
  end

  test "a frame that isn't JSON is a parse error" do
    post mcp_path, params: "{nope",
      headers: {"Authorization" => "Bearer #{@token}", "Content-Type" => "application/json"}

    assert_equal(-32700, response.parsed_body.dig("error", "code"))
  end

  # Streamable HTTP clients open a GET for server-sent events. There are none
  # to send; 405 is how the spec says so.
  test "GET is not offered" do
    get mcp_path, headers: {"Authorization" => "Bearer #{@token}"}

    assert_response :method_not_allowed
    assert_equal "POST", response.headers["Allow"]
  end

  # --- Who wrote it ---------------------------------------------------------

  test "a write is attributed to the token's agent" do
    rpc "tools/call", {name: "add_note", arguments: {ticket_id: @ticket.id, text: "Checked the logs."}}

    assert_not result["isError"]
    note = @ticket.messages.find_by!(direction: "note")
    assert_equal @agent, note.agent
  end

  test "a token can't write as somebody else" do
    assert_no_difference -> { Message.count } do
      rpc "tools/call", {name: "add_note",
                         arguments: {ticket_id: @ticket.id, text: "Not me.", agent_email: @other.email}}
    end

    assert result["isError"]
    assert_match "sam@spool.test", tool_text
  end

  test "naming yourself is allowed" do
    rpc "tools/call", {name: "add_note",
                       arguments: {ticket_id: @ticket.id, text: "Me.", agent_email: "SAM@spool.test"}}

    assert_not result["isError"]
    assert_equal @agent, @ticket.messages.find_by!(direction: "note").agent
  end

  test "a call records that the token was used" do
    rpc "tools/list"

    assert_not_nil @agent.mcp_token.reload.last_used_at
  end
end
