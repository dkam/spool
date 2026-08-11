require "application_system_test_case"

# Cover for the parts of the design that only exist once JavaScript runs — the
# theme switch, the quoted-text disclosure, the template picker and the
# note/reply toggle. An integration test can prove the markup is on the page;
# only this can prove the controls do anything.
class SpoolUiTest < ApplicationSystemTestCase
  setup do
    @agent = Agent.find_or_create_by!(oidc_sub: "dev-open-mode") do |a|
      a.email = ENV.fetch("SPOOL_DEV_AGENT_EMAIL", "dev@localhost")
      a.name = "Development Agent"
    end

    @customer = Customer.create!(email: "dana@fieldworks.co", name: "Dana Whitmore")
    @ticket = Ticket.create!(customer: @customer, subject: "Can't connect SMTP",
      state: "open", last_activity_at: 5.minutes.ago)

    Message.create!(
      ticket: @ticket, direction: "inbound", message_id: "<in-1@fieldworks.co>",
      from_name: "Dana Whitmore", from_email: "dana@fieldworks.co", sent_at: 5.minutes.ago,
      body: JSON.generate({
        "text" => "It says smtp_tls = auto.\n\nOn Tue, Spool Support wrote:\n> Send me the config dump.",
        "html" => nil
      }),
      body_excerpt: "It says smtp_tls = auto."
    )

    Template.create!(name: "Ask for logs", subject: "Delivery log",
      body: "Could you send the last twenty lines of the delivery log?")
  end

  # Every other test here reaches the thread with `visit ticket_path`, which is
  # why a broken link out of the list survived a green suite. The rows live in
  # the ticket_list turbo-frame, so the navigation has to be told to leave it.
  test "clicking a ticket in the list opens the thread" do
    visit root_path
    click_link "Can't connect SMTP"

    assert_current_path ticket_path(@ticket)
    assert_text "dana@fieldworks.co"
    assert_no_text "Content missing"
  end

  test "clicking a ticket on a customer page opens the thread" do
    visit customer_path(@customer)
    click_link "Can't connect SMTP"

    assert_current_path ticket_path(@ticket)
    assert_no_text "Content missing"
  end

  # The customer screen gets its row targets from the shared partial, so the
  # keys worked there before anything advertised them. A screen that answers to
  # a key has to say so, or the shortcut may as well not exist.
  test "the customer screen offers the keys it actually answers to" do
    visit customer_path(@customer)

    press :shift, "j"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"

    assert_selector "[data-shortcuts-target='hint']", visible: :all, text: /Move/
    # No H here, and the reason is taste rather than mechanism: since origin is
    # paired with its ticket, H *could* work now. It isn't offered because
    # "back" from a customer is genuinely ambiguous between the ticket list and
    # the ticket you followed the customer link from, and a key that picks one
    # of two plausible meanings is worse than a key that isn't offered.
    assert_no_selector "[data-shortcuts-target='back']"
  end

  test "the theme switch applies dark and survives a navigation" do
    visit root_path
    assert_equal "light", page.find("html")[:"data-theme"]

    click_button "Dark"
    assert_equal "dark", page.find("html")[:"data-theme"]

    # Persisted in localStorage and reapplied by the layout's pre-paint script,
    # so it has to still be dark after a full page load.
    visit ticket_path(@ticket)
    assert_equal "dark", page.find("html")[:"data-theme"]
  end

  test "quoted history is hidden until asked for" do
    visit ticket_path(@ticket)

    assert_no_text "Send me the config dump"
    click_button "Show quoted text"
    assert_text "Send me the config dump"

    click_button "Hide quoted text"
    assert_no_text "Send me the config dump"
  end

  test "a template fills the compose box without sending" do
    visit ticket_path(@ticket)

    assert_no_difference -> { @ticket.messages.count } do
      click_button "Templates"
      click_button "Ask for logs"
      assert_field "body", with: /twenty lines of the delivery log/
    end
  end

  test "switching to a note stops the box naming the customer" do
    visit ticket_path(@ticket)
    assert_text "dana@fieldworks.co"

    click_button "Internal note instead"

    assert_text "Internal note on"
    assert_button "Save note"
    # The recipient must disappear: an agent has to be unable to glance at a
    # note and think the customer will see it.
    assert_no_selector "[data-composer-target='recipient']", visible: true
  end

  test "sending a reply from the box adds it to the thread" do
    visit ticket_path(@ticket)

    fill_in "body", with: "Pin smtp_tls to starttls."
    click_button "Send reply"

    assert_text "Pin smtp_tls to starttls."
    # Rendered uppercase by the stylesheet, so match the label case-insensitively
    # rather than asserting on how CSS happened to draw it.
    assert_text(/sent to customer/i)
    assert_equal "pending", @ticket.reload.state
  end

  # --- Keyboard -------------------------------------------------------------

  test "shift-gated keys walk the list, open a ticket and come back to it" do
    older = Ticket.create!(customer: @customer, subject: "Bounce report",
      state: "open", last_activity_at: 2.hours.ago)

    visit root_path
    assert_no_selector "[data-selected]"

    press :shift, "j"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"

    press :shift, "j"
    assert_selector "a[data-selected][data-ticket-id='#{older.id}']"

    press :shift, "k"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"

    press :shift, "l"
    assert_selector "h1", text: "Can't connect SMTP"

    press :shift, "h"
    assert_selector "h1", text: "Tickets"
    # The whole point of remembering: you come back to the row you left, not
    # to the top of the list.
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"
  end

  test "back returns to the filtered list a ticket was opened from" do
    visit tickets_path(state: "open")

    press :shift, "j"
    press :shift, "l"
    assert_selector "h1", text: "Can't connect SMTP"

    press :shift, "h"
    assert_current_path tickets_path(state: "open")
  end

  test "a ticket opened cold goes back to the list, not to somewhere it has never been" do
    other = Ticket.create!(customer: @customer, subject: "Bounce report",
      state: "open", last_activity_at: 2.hours.ago)

    # Leave a filtered list in the tab's memory, recorded against @ticket.
    visit tickets_path(state: "open")
    press :shift, "j"
    press :shift, "l"

    # Now arrive somewhere else the way a pasted link does — no list behind it.
    visit ticket_path(other)
    press :shift, "h"

    # The breadcrumb, not the filter belonging to a different ticket.
    assert_current_path root_path
  end

  test "typing a capital in the composer is not a shortcut" do
    visit ticket_path(@ticket)

    find_field("body").send_keys([:shift, "h"], "old on — checking the logs.")

    assert_field "body", with: /\AHold on/
    # Shift+H is "go back" everywhere else on this screen. Inside the box it
    # has to be a letter, or the reply you were writing is gone.
    assert_selector "h1", text: "Can't connect SMTP"
  end

  test "holding shift says what the screen answers to" do
    visit root_path
    assert_no_selector "[data-shortcuts-target='hint']", visible: true

    page.driver.browser.action.key_down(:shift).perform
    assert_selector "[data-shortcuts-target='hint']", text: /move/i

    page.driver.browser.action.key_up(:shift).perform
    assert_no_selector "[data-shortcuts-target='hint']", visible: true
  end

  test "customer notes save themselves" do
    visit customer_path(@customer)

    fill_in_notes "Prefers email over calls."

    assert_text "Saved"
    assert_equal "Prefers email over calls.", @customer.reload.notes
  end

  private

  # Sent at the document rather than at a field: the shortcuts listen on
  # window, and a test that focuses something first would be testing a
  # different thing than the one a user does.
  def press(*sequence)
    find("body").send_keys(sequence)
  end

  def fill_in_notes(text)
    field = find("[data-notes-target='field']")
    field.set(text)
    # Blur flushes the debounce rather than waiting it out.
    find("h1").click
  end
end
