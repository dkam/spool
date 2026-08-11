require "test_helper"

# End-to-end cover for the three screens: that they render, that the filters
# filter, and — the part worth testing — that the write paths behind the design's
# controls actually do what the control claims.
#
# Runs in open mode (no OIDC env vars), so `current_agent` is the stand-in
# development agent. See docs/auth.md.
class UiFlowsTest < ActionDispatch::IntegrationTest
  setup do
    # Open mode provisions the stand-in agent lazily on first request, but that
    # write lands on a GET, which the database selector routes to a read-only
    # connection. Creating the row up front keeps these tests about the screens.
    # The lazy path itself is a bug in Authentication#development_agent, raised
    # with its owner rather than worked around here.
    @agent = Agent.find_or_create_by!(oidc_sub: "dev-open-mode") do |a|
      a.email = ENV.fetch("SPOOL_DEV_AGENT_EMAIL", "dev@localhost")
      a.name = "Development Agent"
    end

    @customer = Customer.create!(email: "dana@fieldworks.co", name: "Dana Whitmore")
    @ticket = Ticket.create!(
      customer: @customer, subject: "Can't connect SMTP after upgrade to 2.4",
      state: "open", last_activity_at: 10.minutes.ago
    )
    @inbound = Message.create!(
      ticket: @ticket, direction: "inbound", message_id: "<in-1@fieldworks.co>",
      from_name: "Dana Whitmore", from_email: "dana@fieldworks.co",
      sent_at: 10.minutes.ago,
      body: JSON.generate({"text" => "Nothing leaves the outbox.", "html" => nil}),
      body_excerpt: "Nothing leaves the outbox."
    )
  end

  attr_reader :agent

  # --- Ticket list ----------------------------------------------------------

  test "the list renders a ticket with its customer and preview" do
    get root_path

    assert_response :success
    assert_select "h1", "Tickets"
    assert_match "Can&#39;t connect SMTP after upgrade to 2.4", response.body
    assert_match "dana@fieldworks.co", response.body
    assert_match "Nothing leaves the outbox.", response.body
  end

  test "state filter maps the design's vocabulary onto the column's" do
    Ticket.create!(customer: @customer, subject: "A closed one",
      state: "closed", last_activity_at: 1.day.ago)

    get tickets_path(state: "closed")
    assert_response :success
    assert_match "A closed one", response.body
    assert_no_match(/Can&#39;t connect SMTP/, response.body)

    # "waiting" is the design's word for the "pending" the column stores.
    @ticket.update!(state: "pending")
    get tickets_path(state: "waiting")
    assert_match "Can&#39;t connect SMTP", response.body
  end

  test "assignee filter separates mine, someone else's and unassigned" do
    other = Agent.create!(oidc_sub: "other", email: "ines@northgate.dev", name: "Ines Adler")
    mine = Ticket.create!(customer: @customer, subject: "Mine", assignee: agent,
      state: "open", last_activity_at: 1.hour.ago)
    theirs = Ticket.create!(customer: @customer, subject: "Theirs", assignee: other,
      state: "open", last_activity_at: 1.hour.ago)

    get tickets_path(assignee: "me")
    assert_match "Mine", response.body
    assert_no_match(/Theirs/, response.body)

    get tickets_path(assignee: other.id)
    assert_match "Theirs", response.body
    assert_no_match(/>Mine</, response.body)

    get tickets_path(assignee: "unassigned")
    assert_match "Can&#39;t connect SMTP", response.body
    assert_no_match(/>Mine</, response.body)
    assert_not_nil theirs
    assert_not_nil mine
  end

  # The keyboard is tested for real in the system suite; this only guards the
  # hooks it hangs off, because they are markup a refactor can quietly drop and
  # nothing else on the page would look any different for it.
  test "list rows carry the hooks the keyboard needs" do
    get root_path

    assert_select "a[data-shortcuts-target=row][data-ticket-id=?]", @ticket.id.to_s
    assert_select "[data-shortcuts-target=hint]"
  end

  # --- Ticket detail --------------------------------------------------------

  test "opening a ticket marks it read for this agent" do
    assert @ticket.unread_for?(agent), "fixture should start unread"

    get ticket_path(@ticket)

    assert_response :success
    assert_not @ticket.reload.unread_for?(agent)
  end

  test "the thread distinguishes a note from a sent reply" do
    Message.compose!(ticket: @ticket, agent: agent, text: "Told the customer.")
    Message.compose!(ticket: @ticket, agent: agent, text: "Same as #1031.", direction: "note")

    get ticket_path(@ticket)

    assert_response :success
    assert_match "Sent to customer", response.body
    assert_match "Internal note · not sent to the customer", response.body
  end

  # --- Composing ------------------------------------------------------------

  test "sending a reply writes an outbound message and hands the ball back" do
    assert_difference -> { @ticket.messages.outbound.count }, 1 do
      post ticket_messages_path(@ticket), params: {body: "Pin smtp_tls to starttls."}
    end

    assert_redirected_to ticket_path(@ticket, anchor: "message-#{Message.last.id}")
    assert_equal "pending", @ticket.reload.state
    assert_equal "Pin smtp_tls to starttls.", Message.last.body_excerpt
  end

  test "saving a note does not change state and is never outbound" do
    @ticket.update!(state: "open")

    assert_difference -> { @ticket.messages.notes.count }, 1 do
      post ticket_messages_path(@ticket), params: {body: "Check box two.", direction: "note"}
    end

    assert_equal "open", @ticket.reload.state, "a note must not hand the ball to the customer"
    assert_nil Message.last.in_reply_to, "a note must not claim a place in the mail thread"
  end

  test "an empty reply is refused rather than written" do
    assert_no_difference -> { @ticket.messages.count } do
      post ticket_messages_path(@ticket), params: {body: "   "}
    end

    assert_redirected_to ticket_path(@ticket, anchor: "compose")
  end

  # --- Ticket controls ------------------------------------------------------

  test "assigning and closing from the ticket header" do
    patch ticket_path(@ticket), params: {ticket: {assignee_id: agent.id}}
    assert_equal agent.id, @ticket.reload.assignee_id

    patch ticket_path(@ticket), params: {ticket: {state: "closed"}}
    assert_equal "closed", @ticket.reload.state

    patch ticket_path(@ticket), params: {ticket: {assignee_id: ""}}
    assert_nil @ticket.reload.assignee_id
  end

  # --- Customer screen ------------------------------------------------------

  test "the customer screen lists their tickets" do
    get customer_path(@customer)

    assert_response :success
    assert_select "h1", "Dana Whitmore"
    assert_match "Can&#39;t connect SMTP", response.body
    assert_match "fieldworks.co", response.body
  end

  test "notes autosave writes and answers no_content" do
    patch customer_path(@customer),
      params: {customer: {notes: "Prefers email over calls."}},
      as: :json

    assert_response :no_content
    assert_equal "Prefers email over calls.", @customer.reload.notes
  end

  # --- Attachments ----------------------------------------------------------

  test "an attachment downloads under the filename from the join row" do
    blob = Attachment.store!("smtp_tls = auto\n", content_type: "text/plain")
    join = MessageAttachment.create!(message: @inbound, attachment: blob,
      filename: "smtp-config.txt")

    get attachment_path(join)

    assert_response :success
    assert_equal "smtp_tls = auto\n", response.body
    assert_match "smtp-config.txt", response.headers["Content-Disposition"]
  end
end
