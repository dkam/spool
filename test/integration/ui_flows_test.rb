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
    follow_redirect!

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

  test "a bare inbox URL means Open, the state an inbox is for" do
    Ticket.create!(customer: @customer, subject: "A closed one",
      state: "closed", last_activity_at: 1.day.ago)

    get root_path
    assert_redirected_to tickets_path(state: "open")

    follow_redirect!
    assert_match "Can&#39;t connect SMTP", response.body
    assert_no_match(/A closed one/, response.body)
  end

  test "the list remembers the view you left and restores it on a bare URL" do
    get tickets_path(state: "closed", assignee: "unassigned")

    get root_path
    assert_redirected_to tickets_path(state: "closed", assignee: "unassigned")
  end

  test "All is an explicit choice and is remembered like any other" do
    Ticket.create!(customer: @customer, subject: "A closed one",
      state: "closed", last_activity_at: 1.day.ago)

    get tickets_path(state: "all")
    assert_match "Can&#39;t connect SMTP", response.body
    assert_match "A closed one", response.body

    get root_path
    assert_redirected_to tickets_path(state: "all")
  end

  test "the search query is part of the remembered view" do
    get tickets_path(state: "open", q: "outbox")

    get root_path
    assert_redirected_to tickets_path(state: "open", q: "outbox")

    # Clearing the search updates the memory too — it does not come back.
    get tickets_path(state: "open")
    get root_path
    assert_redirected_to tickets_path(state: "open")
  end

  # The header search box on a ticket screen submits a query but no filters —
  # it has no list in front of it to read them from. That must keep the state
  # you were browsing in, not silently reset it.
  test "a search URL without a state keeps the remembered one" do
    get tickets_path(state: "closed")

    get tickets_path(q: "outbox")
    assert_response :success
    assert_select "input[name=state][value=closed]"
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
    follow_redirect!

    assert_select "a[data-shortcuts-target=row][data-ticket-id=?]", @ticket.id.to_s
    assert_select "[data-shortcuts-target=hint]"
  end

  # --- Search ---------------------------------------------------------------

  test "search narrows the list to tickets whose messages match" do
    other = Ticket.create!(customer: @customer, subject: "Invoice for July",
      state: "open", last_activity_at: 1.hour.ago)
    Message.create!(ticket: other, direction: "inbound", message_id: "<in-2@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 1.hour.ago,
      body: JSON.generate({"text" => "Could you resend it?", "html" => nil}),
      body_excerpt: "Could you resend it?")

    get tickets_path(q: "outbox")

    assert_response :success
    assert_match "Can&#39;t connect SMTP", response.body
    assert_no_match(/Invoice for July/, response.body)
  end

  # The reason search returns a message id and not just a ticket id.
  test "a result previews the message that matched, not the newest one" do
    # compose! hands the ball to the customer, so the ticket is now pending —
    # search across all states, this test is about the preview.
    Message.compose!(ticket: @ticket, agent: agent, text: "Glad that sorted it.")

    get tickets_path(q: "outbox", state: "all")

    assert_response :success
    assert_match "Nothing leaves the outbox.", response.body
    assert_no_match(/Glad that sorted it/, response.body)
  end

  test "search composes with the state filter rather than replacing it" do
    get tickets_path(q: "outbox", state: "closed")

    assert_response :success
    assert_no_match(/Can&#39;t connect SMTP/, response.body)
    # The filter is the likeliest reason a search looks empty and the least
    # visible, so the empty state has to name it and offer the way past it.
    assert_match "in this filter", response.body
    assert_select "a", text: "Search all tickets"
  end

  test "a customer match is a person, not their tickets" do
    get tickets_path(q: "fieldworks")

    assert_response :success
    assert_select "a[href=?]", customer_path(@customer)
    assert_match "People", response.body
  end

  # These rows live inside the ticket_list frame, so a link without an explicit
  # target is scoped to that frame, finds no match in customers/show and renders
  # "Content missing". It shipped that way once; this is the guard.
  test "a person row escapes the ticket_list frame" do
    get tickets_path(q: "fieldworks")

    assert_response :success
    assert_select "a[href=?][data-turbo-frame=_top]", customer_path(@customer)
  end

  test "customer search matches inside an address, not just at the start" do
    # The infix case is exactly what FTS5 cannot do and why this half is LIKE.
    assert_equal [@customer], Customer.search("ieldwork").to_a
    assert_equal [], Customer.search("%").to_a
  end

  test "one character is not a search" do
    get tickets_path(q: "o")

    assert_response :success
    # The list stays exactly as it was rather than being narrowed by a letter
    # that matches most of the table, and no People section appears.
    assert_match "Can&#39;t connect SMTP", response.body
    assert_no_match(/People/, response.body)
    # The box still holds what has been typed so far, and the chip says so.
    assert_select "input[name=q][value=?]", "o"
  end

  test "search caps on tickets, not on matching messages" do
    # Two messages in one ticket both matching: a message-level cap of 1 would
    # return one ticket here and hide the other entirely.
    quiet = Ticket.create!(customer: @customer, subject: "Second thread",
      state: "open", last_activity_at: 2.hours.ago)
    Message.create!(ticket: quiet, direction: "inbound", message_id: "<in-3@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 2.hours.ago,
      body: JSON.generate({"text" => "outbox again", "html" => nil}),
      body_excerpt: "outbox again")
    Message.create!(ticket: @ticket, direction: "inbound", message_id: "<in-4@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 9.minutes.ago,
      body: JSON.generate({"text" => "still the outbox", "html" => nil}),
      body_excerpt: "still the outbox")

    matches = Search::Fts.ticket_matches("outbox", limit: 2)

    assert_equal 2, matches.size, "expected one entry per ticket, not per message"
    assert_equal [@ticket.id, quiet.id].sort, matches.keys.sort
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

  # --- The signed-out header ------------------------------------------------

  OIDC = {
    "OIDC_CLIENT_ID" => "spool",
    "OIDC_CLIENT_SECRET" => "secret",
    "OIDC_DISCOVERY_URL" => "https://clinch.example.com"
  }.freeze

  # The login screen renders the layout, so every control in the header is on a
  # page belonging to someone who cannot use any of them.
  test "the login screen offers no controls a locked-out person cannot use" do
    with_env(OIDC) do
      get login_path

      assert_response :success
      assert_select "input[name=q]", false, "the search box answers nothing signed out"
      assert_select "header nav a", false, "a Tickets link here returns you to this page"

      # What is still worth showing: which instance this is, and the way in.
      assert_match ENV.fetch("SPOOL_MAILBOX", "support@example.com"), response.body
      assert_select "a[href=?]", "/login/start"
    end
  end

  # Open mode has no session at all, so `authenticated?` is false on a wholly
  # usable app. Gating the header on that instead of on current_agent would
  # take the nav and the search away from every development instance.
  test "open mode still gets the nav and the search" do
    get root_path
    follow_redirect!

    assert_response :success
    assert_select "input[name=q]"
    assert_select "header nav a", text: "Tickets"
  end

  # --- The footer -----------------------------------------------------------

  test "the footer says which release and what it is running on" do
    get root_path
    follow_redirect!

    assert_select "footer" do
      assert_select "a[href=?]", Spool::SOURCE_URL, text: "GitHub"
      assert_select "a[href=?]", "#{Spool::SOURCE_URL}/releases/tag/v#{Spool::VERSION}"
    end
    assert_match "Rails", response.body
    assert_match Rails.version, response.body
    assert_match RUBY_VERSION, response.body
  end

  test "a known revision links to the commit it came from" do
    original = Rails.application.config.x.revision
    Rails.application.config.x.revision = "abc1234"

    get root_path
    follow_redirect!

    assert_select "footer a[href=?]", "#{Spool::SOURCE_URL}/commit/abc1234", text: "abc1234"
  ensure
    Rails.application.config.x.revision = original
  end

  # Outside a container and outside development there is no revision to report.
  # A footer reading "unknown" looks like a value; the absence reads as what it
  # is, which is that this build never recorded one.
  test "an unknown revision is left out rather than printed" do
    original = Rails.application.config.x.revision
    Rails.application.config.x.revision = "unknown"

    get root_path
    follow_redirect!

    assert_select "footer" do |footer|
      assert_no_match(/unknown/, footer.first.to_s)
    end
  ensure
    Rails.application.config.x.revision = original
  end

  # The one screen where "which instance is this, and is it current?" is most
  # likely to be asked, and the one screen that renders none of the app.
  test "the footer is on the login screen too" do
    with_env(OIDC) do
      get login_path

      assert_select "footer a[href=?]", Spool::SOURCE_URL
    end
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
