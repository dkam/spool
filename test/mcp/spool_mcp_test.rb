# frozen_string_literal: true

require "test_helper"

# The MCP tools, called directly as classes. The stdio transport and JSON-RPC
# framing are the gem's to test; what is Spool's is that each tool speaks the
# UI's vocabulary, narrows like the inbox does, and writes through the same
# supported paths as the controllers.
#
# Note the server's schema validation (bad enum values, missing required
# arguments) only runs on the transport path — a direct .call bypasses it, so
# these tests exercise the tools' own error handling too.
class SpoolMcpTest < ActiveSupport::TestCase
  setup do
    @customer = Customer.create!(email: "dana@fieldworks.co", name: "Dana Whitmore")
    @agent = Agent.create!(oidc_sub: "agent-1", email: "sam@spool.test", name: "Sam")

    @open = Ticket.create!(
      customer: @customer, subject: "Outbox stuck", state: "open",
      last_activity_at: 10.minutes.ago
    )
    @closed = Ticket.create!(
      customer: @customer, subject: "A closed one", state: "closed",
      last_activity_at: 2.days.ago
    )

    @inbound = Message.create!(
      ticket: @open, direction: "inbound", message_id: "<in-1@fieldworks.co>",
      from_name: "Dana Whitmore", from_email: "dana@fieldworks.co",
      sent_at: 10.minutes.ago,
      body: JSON.generate({"text" => "Nothing leaves the outbox.", "html" => nil}),
      body_excerpt: "Nothing leaves the outbox."
    )
  end

  # Every tool returns a Response whose single content item is JSON (or a bare
  # error message when isError is set).
  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  test "list_tickets defaults to open, the same default as the inbox" do
    result = payload(SpoolMcp::ListTickets.call)

    ids = result[:tickets].map { |t| t[:id] }
    assert_includes ids, @open.id
    assert_not_includes ids, @closed.id
  end

  test "list_tickets previews the latest message and speaks the UI's state words" do
    row = payload(SpoolMcp::ListTickets.call).fetch(:tickets).find { |t| t[:id] == @open.id }

    assert_equal "open", row[:state]
    assert_equal "Nothing leaves the outbox.", row[:preview]
    assert_equal "dana@fieldworks.co", row.dig(:customer, :email)
  end

  test "list_tickets waiting means the pending column" do
    @open.update!(state: "pending")

    result = payload(SpoolMcp::ListTickets.call(state: "waiting"))

    assert_equal [@open.id], result[:tickets].map { |t| t[:id] }
    assert_equal "waiting", result[:tickets].first[:state]
  end

  test "list_tickets narrows by search and previews the message that matched" do
    Message.create!(
      ticket: @open, direction: "inbound", message_id: "<in-2@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 1.minute.ago,
      body: JSON.generate({"text" => "Thanks, that worked.", "html" => nil}),
      body_excerpt: "Thanks, that worked."
    )

    result = payload(SpoolMcp::ListTickets.call(q: "outbox", state: "all"))

    assert_equal [@open.id], result[:tickets].map { |t| t[:id] }
    # The hit, not the newest message — otherwise you can't see why it matched.
    assert_equal "Nothing leaves the outbox.", result[:tickets].first[:preview]
  end

  test "list_tickets by assignee email, and an unknown email is an error not an empty list" do
    @open.update!(assignee: @agent)

    result = payload(SpoolMcp::ListTickets.call(assignee: "sam@spool.test"))
    assert_equal [@open.id], result[:tickets].map { |t| t[:id] }

    response = SpoolMcp::ListTickets.call(assignee: "nobody@spool.test")
    assert response.error?
    assert_match "nobody@spool.test", response.content.first[:text]
  end

  test "get_ticket returns the thread oldest first with notes marked" do
    ApplicationRecord.writing do
      Message.compose!(ticket: @open, agent: @agent, text: "Checking the relay logs.", direction: "note")
    end

    result = payload(SpoolMcp::GetTicket.call(id: @open.id))

    assert_equal %w[inbound note], result[:messages].map { |m| m[:direction] }
    assert_equal "dana@fieldworks.co", result[:messages].first.dig(:from, :email)
    assert_equal "Nothing leaves the outbox.", result[:messages].first[:body]
    assert_equal "sam@spool.test", result[:messages].last.dig(:from, :email)
  end

  test "get_ticket with an unknown id is an error response, not an exception" do
    response = SpoolMcp::GetTicket.call(id: 999_999)

    assert response.error?
    assert_match "999999", response.content.first[:text]
  end

  test "add_note goes through compose!, leaves state alone, and signs as the stand-in by default" do
    result = payload(SpoolMcp::AddNote.call(ticket_id: @open.id, text: "Seen this before — DNS."))

    note = Message.find(result[:message_id])
    assert note.note?
    assert_equal "mcp@localhost", note.agent.email
    assert_equal "open", @open.reload.state
  end

  test "a named agent must exist — writes never provision colleagues" do
    response = SpoolMcp::AddNote.call(ticket_id: @open.id, text: "x", agent_email: "typo@spool.test")

    assert response.error?
    assert_no_difference "Agent.count" do
      SpoolMcp::AddNote.call(ticket_id: @open.id, text: "x", agent_email: "typo@spool.test")
    end
  end

  test "reply_to_ticket records an outbound reply and hands the ball to the customer" do
    result = payload(
      SpoolMcp::ReplyToTicket.call(ticket_id: @open.id, text: "Fixed — try again?", agent_email: "sam@spool.test")
    )

    message = Message.find(result[:message_id])
    assert message.outbound?
    assert_equal @inbound.message_id, message.in_reply_to
    assert_equal "waiting", result[:state]
    # Mailgun is never configured in test, and the tool says so out loud.
    assert_match(/not configured/, result[:delivery])
    assert_equal "pending", @open.reload.state
  end

  test "update_ticket closes, assigns and unassigns in UI vocabulary" do
    result = payload(SpoolMcp::UpdateTicket.call(id: @open.id, state: "closed", assignee: "sam@spool.test"))
    assert_equal "closed", result[:state]
    assert_equal "sam@spool.test", result[:assignee]
    assert_equal "closed", @open.reload.state

    result = payload(SpoolMcp::UpdateTicket.call(id: @open.id, assignee: "unassigned"))
    assert_nil result[:assignee]
    assert_nil @open.reload.assignee_id
  end

  test "update_ticket rejects a state outside the vocabulary" do
    # The transport's schema validation catches this for real clients; a direct
    # call has to be caught by the tool itself.
    response = SpoolMcp::UpdateTicket.call(id: @open.id, state: "pending")

    assert response.error?
    assert_equal "open", @open.reload.state
  end

  test "update_ticket with nothing to change says so" do
    response = SpoolMcp::UpdateTicket.call(id: @open.id)

    assert response.error?
  end

  test "list_tickets hides spam like the inbox does, and the tag parameter is the way in" do
    @open.mark_spam!

    assert_empty payload(SpoolMcp::ListTickets.call)[:tickets]
    assert_empty payload(SpoolMcp::ListTickets.call(state: "all"))[:tickets]
      .reject { |t| t[:id] == @closed.id }

    rows = payload(SpoolMcp::ListTickets.call(tag: "spam"))[:tickets]
    assert_equal [@open.id], rows.map { |t| t[:id] }
    assert_equal ["spam"], rows.first[:tags]
  end

  test "update_ticket tagging spam blocks the sender; removing it unblocks" do
    result = payload(SpoolMcp::UpdateTicket.call(id: @open.id, add_tags: ["spam"]))

    assert_equal ["spam"], result[:tags]
    assert @customer.reload.blocked?

    result = payload(SpoolMcp::UpdateTicket.call(id: @open.id, remove_tags: ["spam"]))

    assert_nil result[:tags]
    assert_not @customer.reload.blocked?
  end

  test "update_ticket plain tags are labels only and never touch the customer" do
    result = payload(SpoolMcp::UpdateTicket.call(id: @open.id, add_tags: ["Billing"]))

    assert_equal ["billing"], result[:tags], "names are normalised to lowercase"
    assert_not @customer.reload.blocked?
  end

  test "the server registers every tool" do
    tools = SpoolMcp.server.tools.keys

    assert_equal %w[add_note get_ticket list_tickets reply_to_ticket update_ticket], tools.sort
  end
end
