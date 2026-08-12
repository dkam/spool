require "application_system_test_case"

# Cover for the parts of the design that only exist once JavaScript runs — the
# theme switch, the quoted-text disclosure, the template picker and the
# note/reply toggle. An integration test can prove the markup is on the page;
# only this can prove the controls do anything.
class SpoolUiTest < ApplicationSystemTestCase
  # --color-accent, as getComputedStyle reports it.
  ACCENT = "rgb(240, 89, 42)"

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

  # --- Search ---------------------------------------------------------------

  test "typing in the search box narrows the list in place" do
    other = Ticket.create!(customer: @customer, subject: "Invoice for July",
      state: "open", last_activity_at: 1.hour.ago)
    Message.create!(ticket: other, direction: "inbound", message_id: "<in-9@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 1.hour.ago,
      body: JSON.generate({"text" => "Could you resend it?", "html" => nil}),
      body_excerpt: "Could you resend it?")

    visit root_path
    assert_text "Invoice for July"

    fill_in "q", with: "smtp_tls"

    assert_no_text "Invoice for July"
    assert_text "Can't connect SMTP"
    # The whole point of the frame: the URL keeps up, so the state you typed
    # into is linkable and the back button still means something.
    assert_current_path(/q=smtp_tls/)
    # And the box was never replaced, so what you typed is still in it.
    assert_equal "smtp_tls", find_field("q").value
  end

  test "the search key works shifted or not — they are the same key" do
    visit root_path

    press "/"
    assert_equal "q", evaluate_script("document.activeElement.id")

    find("h1").click
    assert_not_equal "q", evaluate_script("document.activeElement.id")

    # Shift + the same physical key types "?", which has to land in the same
    # place or the shortcut works depending on a finger.
    press :shift, "/"
    assert_equal "q", evaluate_script("document.activeElement.id")
  end

  # The latch exists for exactly this: after typing, the caret is in the search
  # box and every shortcut is correctly suppressed, so there is otherwise no
  # keyboard route from the box into the results you just asked for.
  test "double-tapping shift hands the keys back after a search" do
    other = Ticket.create!(customer: @customer, subject: "Invoice for July",
      state: "open", last_activity_at: 1.hour.ago)
    Message.create!(ticket: other, direction: "inbound", message_id: "<in-8@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 1.hour.ago,
      body: JSON.generate({"text" => "smtp_tls again on the invoice box", "html" => nil}),
      body_excerpt: "smtp_tls again on the invoice box")

    visit root_path
    fill_in "q", with: "smtp_tls"
    # Wait on the URL, not on the text: both tickets match, so the text is
    # already there before the search runs, and a test that doesn't wait for the
    # response has it land later — on top of a cursor the test has since moved.
    assert_current_path(/q=smtp_tls/)
    assert_text "Invoice for July"

    # Still typing: a bare j belongs in the box, not on the page.
    assert_equal "q", evaluate_script("document.activeElement.id")
    assert_no_selector "[data-selected]"

    double_tap_shift

    # The box let go, and the legend says why bare keys now do something.
    assert_not_equal "q", evaluate_script("document.activeElement.id")
    assert_selector "[data-shortcuts-target='hint'][data-latched]"
    assert_text(/exit/i)

    # Unshifted now.
    press "j"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"
    press "j"
    assert_selector "a[data-selected][data-ticket-id='#{other.id}']"

    press :escape
    assert_no_selector "[data-shortcuts-target='hint'][data-latched]"
    # And unlatched, a bare j is inert again.
    press "k"
    assert_selector "a[data-selected][data-ticket-id='#{other.id}']"
  end

  # Selenium fires two taps within milliseconds; a person tapping a modifier
  # deliberately is far slower than that, and the window has to fit the hand
  # rather than the test harness.
  # A search list holds two kinds of row. The cursor has to walk both, or the
  # People section is visible to the eye and invisible to the keyboard.
  test "j and k walk people as well as tickets in a search" do
    # "dana" has to match both halves for this to test anything: the address
    # via LIKE, and a message via FTS. The fixture ticket matches neither.
    mentioned = Ticket.create!(customer: @customer, subject: "Signed off",
      state: "open", last_activity_at: 1.hour.ago)
    Message.create!(ticket: mentioned, direction: "inbound", message_id: "<in-7@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 1.hour.ago,
      body: JSON.generate({"text" => "Dana asked us to check.", "html" => nil}),
      body_excerpt: "Dana asked us to check.")

    visit tickets_path(q: "dana")
    assert_text(/people/i)

    press :shift, "j"
    # People are rendered above the tickets, so the first row down is a person.
    assert_selector "a[data-selected][data-row-id='customer-#{@customer.id}']"

    press :shift, "j"
    assert_selector "a[data-selected][data-row-id='ticket-#{mentioned.id}']"

    press :shift, "k"
    assert_selector "a[data-selected][data-row-id='customer-#{@customer.id}']"

    press :shift, "l"
    assert_current_path customer_path(@customer)
  end

  # The route everyone actually takes, and the one that was broken: you have
  # just typed, so the caret is in the box, and the answer is on screen right
  # underneath it. ⇧J is no help here — that is how you type a capital J, so the
  # chord that drives every other list on the site puts a letter in the query
  # and empties the results you were reaching for.
  test "arrows reach the results without leaving the search box" do
    mentioned = Ticket.create!(customer: @customer, subject: "Signed off",
      state: "open", last_activity_at: 1.hour.ago)
    Message.create!(ticket: mentioned, direction: "inbound", message_id: "<in-5@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 1.hour.ago,
      body: JSON.generate({"text" => "Dana asked us to check.", "html" => nil}),
      body_excerpt: "Dana asked us to check.")

    visit root_path
    press "/"
    find_field("q").send_keys("dana")
    assert_text(/people/i)

    find_field("q").send_keys(:arrow_down)
    assert_selector "a[data-selected][data-row-id='customer-#{@customer.id}']"
    # And without putting the box down: another letter still goes in the query.
    assert_equal "q", evaluate_script("document.activeElement.id")

    find_field("q").send_keys(:arrow_down)
    assert_selector "a[data-selected][data-row-id='ticket-#{mentioned.id}']"

    find_field("q").send_keys(:arrow_up)
    assert_selector "a[data-selected][data-row-id='customer-#{@customer.id}']"

    find_field("q").send_keys(:enter)
    assert_current_path customer_path(@customer)
  end

  # The reason the letters can't be shortcuts in there. J, K, L and H begin
  # Jane, Kevin, Lisa and Harry, which is exactly what a people search is for.
  test "a capital letter in the search box is a letter" do
    visit root_path
    press "/"
    find_field("q").send_keys([:shift, "j"], "ane")

    assert_equal "Jane", find_field("q").value
    assert_no_selector "[data-selected]"
  end

  # Every other keyboard test here asserts `[data-selected]` — the attribute,
  # not the paint. That is why a person row could be selected, and correct in
  # the DOM, while nothing on screen moved: its dot was missing the `rail-dot`
  # class the selection styles hang off. This one reads the pixel.
  test "the selected row lights its dot, whichever kind of row it is" do
    mentioned = Ticket.create!(customer: @customer, subject: "Signed off",
      state: "open", last_activity_at: 1.hour.ago)
    Message.create!(ticket: mentioned, direction: "inbound", message_id: "<in-4@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 1.hour.ago,
      body: JSON.generate({"text" => "Dana asked us to check.", "html" => nil}),
      body_excerpt: "Dana asked us to check.")

    person = "a[data-row-id='customer-#{@customer.id}']"
    ticket = "a[data-row-id='ticket-#{mentioned.id}']"

    visit tickets_path(q: "dana")
    assert_text(/people/i)
    assert_not_equal ACCENT, dot_colour(person)

    press :shift, "j"
    assert_selector "#{person}[data-selected]"
    assert_equal ACCENT, dot_colour(person)

    press :shift, "j"
    assert_equal ACCENT, dot_colour(ticket)
    # And the one you left goes back to being an ordinary dot.
    assert_not_equal ACCENT, dot_colour(person)
  end

  # The cold visit above is the easy half. Nobody arrives at a search cold —
  # they were already walking the list, so the cursor is already somewhere, and
  # the question is what it means once the list underneath it has changed.
  test "a search starts the cursor at the top of what it found" do
    mentioned = Ticket.create!(customer: @customer, subject: "Signed off",
      state: "open", last_activity_at: 1.hour.ago)
    Message.create!(ticket: mentioned, direction: "inbound", message_id: "<in-6@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 1.hour.ago,
      body: JSON.generate({"text" => "Dana asked us to check.", "html" => nil}),
      body_excerpt: "Dana asked us to check.")

    # Down onto the ticket that the coming search will also match — the cursor
    # has to survive the narrowing for this to test anything.
    visit root_path
    press :shift, "j"
    press :shift, "j"
    assert_selector "a[data-selected][data-row-id='ticket-#{mentioned.id}']"

    press "/"
    find_field("q").send_keys("dana")
    assert_text(/people/i)

    double_tap_shift
    press "j"

    # People are rendered first, so the first row down is a person — whatever
    # the cursor was pointing at before the search was asked.
    assert_selector "a[data-selected][data-row-id='customer-#{@customer.id}']"
  end

  # Same rule, the other way of asking a different question. Stated separately
  # because the comment in the controller claims both and only one of them is
  # the bug that was reported.
  test "changing a filter starts the cursor at the top too" do
    Ticket.create!(customer: @customer, subject: "Bounce report",
      state: "open", last_activity_at: 2.hours.ago)

    visit root_path
    press :shift, "j"
    press :shift, "j"
    assert_selector "[data-selected]"

    click_link "Open"
    assert_current_path(/state=open/)
    assert_no_selector "[data-selected]"
  end

  test "a deliberate, human-paced double tap still latches" do
    visit root_path

    double_tap_shift gap: 0.5

    assert_selector "[data-shortcuts-target='hint'][data-latched]"
  end

  # A tap is a Shift on its own. ⇧J is a shortcut, and its release used to arm
  # the second half of a double tap — so the next lone Shift completed one,
  # latching the mode, and the one after that unlatched it. Using the keyboard
  # was the thing that made the keyboard behave unpredictably.
  test "using a shift shortcut does not prime the latch" do
    visit root_path
    press :shift, "j"
    assert_selector "[data-selected]"

    tap_shift
    assert_no_selector "[data-shortcuts-target='hint'][data-latched]"
    # Nothing latched, so a bare j is still inert.
    press "j"
    assert_selector "a[data-selected][data-row-id='ticket-#{@ticket.id}']"
  end

  test "typing a capital does not latch shortcut mode" do
    visit ticket_path(@ticket)

    # Shift, letter, Shift, letter — two Shift presses, but not a double tap.
    find_field("body").send_keys([:shift, "h"], "ello", [:shift, "t"], "here")

    assert_field "body", with: "HelloThere"
    assert_no_selector "[data-shortcuts-target='hint'][data-latched]"
  end

  test "escape empties the box and gives the list back" do
    visit root_path
    fill_in "q", with: "smtp_tls"
    assert_current_path(/q=smtp_tls/)

    find_field("q").send_keys(:escape)

    assert_equal "", find_field("q").value
    assert_no_current_path(/q=/)
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

  # Two discrete taps, not one hold — the controller times the gap from the
  # release, so key_up has to happen between them.
  def double_tap_shift(gap: 0)
    tap_shift
    sleep gap
    tap_shift
  end

  def tap_shift
    page.driver.browser.action.key_down(:shift).key_up(:shift).perform
  end

  # What the rail dot of a given row is actually painted, so a test can tell
  # "selected" from "looks selected".
  def dot_colour(row_selector)
    evaluate_script(<<~JS)
      (() => {
        const dot = document.querySelector("#{row_selector} .rail-dot")
        return dot ? getComputedStyle(dot).backgroundColor : null
      })()
    JS
  end

  def fill_in_notes(text)
    field = find("[data-notes-target='field']")
    field.set(text)
    # Blur flushes the debounce rather than waiting it out.
    find("h1").click
  end
end
