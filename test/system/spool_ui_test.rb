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

  # The browser outlives the test, and so would an emulated system theme.
  teardown { emulate_color_scheme "" }

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

    press "j"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"

    assert_selector "[data-shortcuts-target='hint']", visible: :all, text: /Move/
    # No H here, and the reason is taste rather than mechanism: since origin is
    # paired with its ticket, H *could* work now. It isn't offered because
    # "back" from a customer is genuinely ambiguous between the ticket list and
    # the ticket you followed the customer link from, and a key that picks one
    # of two plausible meanings is worse than a key that isn't offered.
    assert_no_selector "[data-shortcuts-target='back']"
  end

  test "the theme follows the system until you pick one" do
    emulate_color_scheme "dark"
    visit root_path

    # Applied by the pre-paint script, so the first paint is already dark.
    assert_selector "html[data-theme='dark']"
    assert_selector "button[aria-pressed='true']", text: "Dark"

    # And it keeps following: no reload when the system flips at sunset.
    emulate_color_scheme "light"
    assert_selector "html[data-theme='light']"
    assert_selector "button[aria-pressed='true']", text: "Light"
  end

  test "picking the other theme sticks, and picking the system's again goes back to following it" do
    emulate_color_scheme "light"
    visit root_path

    click_button "Dark"
    assert_selector "html[data-theme='dark']"

    # Persisted in localStorage and reapplied by the layout's pre-paint script,
    # so it has to still be dark after a full page load.
    visit ticket_path(@ticket)
    assert_selector "html[data-theme='dark']"

    # Light is what the system says anyway, so this isn't a preference worth
    # keeping — the proof it was forgotten is that the system leads again.
    click_button "Light"
    assert_selector "html[data-theme='light']"
    emulate_color_scheme "dark"
    assert_selector "html[data-theme='dark']"
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
    # Delivery is async, so the label is the honest "queued" one until Mailgun
    # accepts the send. Rendered uppercase by the stylesheet, so match it
    # case-insensitively rather than asserting on how CSS happened to draw it.
    assert_text(/queued · not yet delivered/i)
    assert_equal "pending", @ticket.reload.state
  end

  # --- Keyboard -------------------------------------------------------------

  test "bare keys walk the list, open a ticket and come back to it" do
    older = Ticket.create!(customer: @customer, subject: "Bounce report",
      state: "open", last_activity_at: 2.hours.ago)

    visit root_path
    assert_no_selector "[data-selected]"

    press "j"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"

    press "j"
    assert_selector "a[data-selected][data-ticket-id='#{older.id}']"

    press "k"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"

    press "l"
    assert_selector "h1", text: "Can't connect SMTP"

    press "h"
    assert_selector "h1", text: "Tickets"
    # The whole point of remembering: you come back to the row you left, not
    # to the top of the list.
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"
  end

  # Shift used to be required. Fingers that learned it shouldn't find the keys
  # dead now that it isn't.
  test "the keys still answer with shift held" do
    visit root_path

    press :shift, "j"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"
  end

  test "enter and the right arrow open the selected row" do
    visit root_path
    press "j"
    press :enter
    assert_selector "h1", text: "Can't connect SMTP"

    visit root_path
    press "j"
    press :arrow_right
    assert_selector "h1", text: "Can't connect SMTP"
  end

  # H, ← and Escape are one gesture — "out of this ticket" — so any of them
  # returns to the list, filter and all.
  test "back returns to the filtered list a ticket was opened from" do
    ["h", :arrow_left, :escape].each do |key|
      visit tickets_path(state: "open")

      press "j"
      press "l"
      assert_selector "h1", text: "Can't connect SMTP"

      press key
      assert_current_path tickets_path(state: "open")
    end
  end

  test "a ticket opened cold goes back to the list, not to somewhere it has never been" do
    other = Ticket.create!(customer: @customer, subject: "Bounce report",
      state: "open", last_activity_at: 2.hours.ago)

    # Leave a filtered list in the tab's memory, recorded against @ticket.
    visit tickets_path(state: "open")
    press "j"
    press "l"

    # Now arrive somewhere else the way a pasted link does — no list behind it.
    visit ticket_path(other)
    press "h"

    # The breadcrumb falls back to the bare inbox URL, which restores the
    # remembered view — not the row-level history belonging to a different
    # ticket.
    assert_current_path tickets_path(state: "open")
  end

  # Triage is reading one ticket after another, and going back to the list
  # between each of them is two keys of overhead per ticket. So on a ticket,
  # J and K move through the list it was opened from — that list, in its order,
  # with its filter.
  test "j and k on a ticket step through the list it was opened from" do
    Ticket.create!(customer: @customer, subject: "Closed in between",
      state: "closed", last_activity_at: 1.hour.ago)
    older = Ticket.create!(customer: @customer, subject: "Bounce report",
      state: "open", last_activity_at: 2.hours.ago)

    visit tickets_path(state: "open")
    press "j"
    press "l"
    assert_selector "h1", text: "Can't connect SMTP"
    assert_selector "[data-shortcuts-target='step']:not([hidden])", visible: :all

    # Past the closed ticket, which the list you came from didn't show.
    press "j"
    assert_selector "h1", text: "Bounce report"

    press "k"
    assert_selector "h1", text: "Can't connect SMTP"

    press "j"
    assert_selector "h1", text: "Bounce report"

    # Back to the list you started from, on the ticket you stepped to rather
    # than the one you opened.
    press "h"
    assert_current_path tickets_path(state: "open")
    assert_selector "a[data-selected][data-ticket-id='#{older.id}']"
  end

  # ↑ and ↓ are how you read a long thread. J and K step; the arrows scroll.
  test "the up and down arrows on a ticket are left to scroll it" do
    Ticket.create!(customer: @customer, subject: "Bounce report",
      state: "open", last_activity_at: 2.hours.ago)

    visit root_path
    press "j"
    press "l"
    assert_selector "h1", text: "Can't connect SMTP"

    press :arrow_down
    sleep 0.3
    assert_selector "h1", text: "Can't connect SMTP"
  end

  test "a ticket opened cold has no list to step through, and doesn't offer one" do
    other = Ticket.create!(customer: @customer, subject: "Bounce report",
      state: "open", last_activity_at: 2.hours.ago)

    # A list in memory — but recorded for @ticket, not for the one pasted next.
    visit root_path
    press "j"
    press "l"
    assert_selector "h1", text: "Can't connect SMTP"

    visit ticket_path(other)
    assert_selector "[data-shortcuts-target='step'][hidden]", visible: :all

    # K would land on @ticket if the other ticket's list answered for this one.
    press "k"
    sleep 0.3
    assert_selector "h1", text: "Bounce report"
  end

  # T is the way out, where H is the way back: it answers "take me to the
  # inbox" without consulting where you have been.
  test "t goes to the ticket list from a ticket and from a customer" do
    visit ticket_path(@ticket)
    press "t"
    assert_selector "h1", text: "Tickets"

    visit customer_path(@customer)
    press "t"
    assert_selector "h1", text: "Tickets"
  end

  test "t returns to the list exactly as you left it" do
    visit tickets_path(state: "closed", q: "outbox")
    assert_selector "[data-shortcuts-target='hint']", visible: :all, text: /Tickets/

    press "t"

    # T visits the bare inbox URL, and the inbox is wherever you last left it —
    # the narrowing you chose comes back rather than being reset. The chips on
    # screen say why the list is short, and All is one click away.
    assert_current_path tickets_path(state: "closed", q: "outbox")
  end

  # With the keys bare, the field check is the only thing between a shortcut
  # and a reply. Every key the page answers to has to be a letter in here.
  test "typing in the composer is not a shortcut" do
    visit ticket_path(@ticket)

    find_field("body").send_keys("hjklt ?/ ", [:shift, "h"], "i")

    assert_field "body", with: "hjklt ?/ Hi"
    assert_selector "h1", text: "Can't connect SMTP"
    assert_no_selector "[data-shortcuts-target='hint']", visible: true
  end

  test "escape in the composer stays in the composer" do
    visit ticket_path(@ticket)

    find_field("body").send_keys("Checking", :escape)

    assert_selector "h1", text: "Can't connect SMTP"
    assert_field "body", with: "Checking"
  end

  test "? says what the screen answers to, and ? again puts it away" do
    visit root_path
    assert_no_selector "[data-shortcuts-target='hint']", visible: true

    press "?"
    assert_selector "[data-shortcuts-target='hint']", text: /move/i

    press "?"
    assert_no_selector "[data-shortcuts-target='hint']", visible: true
  end

  # You open the legend to learn the keys, and every screen's are different —
  # so it stays up as you move until you put it away.
  test "the legend stays up across screens" do
    visit root_path
    press "?"
    press "j"
    press "l"

    assert_selector "h1", text: "Can't connect SMTP"
    assert_selector "[data-shortcuts-target='hint']", text: /back/i
  end

  # New mail refreshes the list by morphing it toward the server's HTML, and
  # the server has never heard of the cursor or the legend. Both belong to the
  # page, and neither should vanish because somebody else's email arrived.
  test "the cursor and the legend survive the page refreshing itself" do
    visit root_path
    press "?"
    press "j"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"

    Ticket.create!(customer: @customer, subject: "Fresh arrival",
      state: "open", last_activity_at: 1.minute.ago)
    refresh_like_a_broadcast
    assert_text "Fresh arrival"

    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"
    assert_selector "[data-shortcuts-target='hint']", text: /move/i
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

  test "/ focuses the search box" do
    visit root_path

    press "/"
    assert_selector "input#q:focus"
  end

  # The box lives on the list, so from anywhere else "/" takes you there. The
  # legends on a ticket and a customer went on offering "/" after the box moved
  # off the header, and pressing it did nothing.
  test "/ from a ticket or a customer goes to the list's search box" do
    visit ticket_path(@ticket)
    press "/"
    assert_selector "h1", text: "Tickets"
    assert_selector "input#q:focus"

    visit customer_path(@customer)
    press "/"
    assert_selector "h1", text: "Tickets"
    assert_selector "input#q:focus"
  end

  # Typed, the caret is in the box and the letters belong to the query. Enter
  # is "that's my question": it puts the box down, so J and K walk the answer.
  test "enter in the search box hands the keys to the results" do
    other = Ticket.create!(customer: @customer, subject: "Invoice for July",
      state: "open", last_activity_at: 1.hour.ago)
    Message.create!(ticket: other, direction: "inbound", message_id: "<in-8@fieldworks.co>",
      from_email: "dana@fieldworks.co", sent_at: 1.hour.ago,
      body: JSON.generate({"text" => "smtp_tls again on the invoice box", "html" => nil}),
      body_excerpt: "smtp_tls again on the invoice box")

    visit root_path
    fill_in "q", with: "smtp_tls"
    find_field("q").send_keys(:enter)
    assert_no_selector "input#q:focus"

    # Both tickets match, so the rows on screen can't say the answer is in.
    assert_list_answers "smtp_tls"

    press "j"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"
    press "j"
    assert_selector "a[data-selected][data-ticket-id='#{other.id}']"
  end

  # A search still waiting out its debounce when the box is put down would land
  # a moment later — after you have started walking the list — and reset the
  # cursor. Putting the box down asks the question now.
  test "putting the search box down asks a pending search at once" do
    visit root_path
    press "/"
    find_field("q").send_keys("smtp_tls")
    # Measured from the keystroke: well inside the debounce, so without a flush
    # there would be no request yet.
    find_field("q").send_keys(:enter)
    assert_current_path(/q=smtp_tls/)

    # Exactly one request for the query: not a submit and then the debounce
    # firing behind it, whose answer is the one that resets the cursor.
    sleep 0.5
    assert_equal 1, evaluate_script(<<~JS)
      performance.getEntriesByType("resource").filter((e) => e.name.includes("q=smtp_tls")).length
    JS
  end

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

    press "j"
    # People are rendered above the tickets, so the first row down is a person.
    assert_selector "a[data-selected][data-row-id='customer-#{@customer.id}']"

    press "j"
    assert_selector "a[data-selected][data-row-id='ticket-#{mentioned.id}']"

    press "k"
    assert_selector "a[data-selected][data-row-id='customer-#{@customer.id}']"

    press "l"
    assert_current_path customer_path(@customer)
  end

  # The route everyone actually takes: you have just typed, so the caret is in
  # the box, and the answer is on screen right underneath it. The letters are
  # no help here — they are the query — but the arrows are free.
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
  test "a letter in the search box is a letter" do
    visit root_path
    press "/"
    find_field("q").send_keys("jane", [:shift, "k"], "?")

    assert_equal "janeK?", find_field("q").value
    assert_no_selector "[data-selected]"
    assert_no_selector "[data-shortcuts-target='hint']", visible: true
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

    press "j"
    assert_selector "#{person}[data-selected]"
    assert_equal ACCENT, dot_colour(person)

    press "j"
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
    press "j"
    press "j"
    assert_selector "a[data-selected][data-row-id='ticket-#{mentioned.id}']"

    press "/"
    find_field("q").send_keys("dana")
    assert_text(/people/i)

    find_field("q").send_keys(:enter)
    assert_no_selector "input#q:focus"
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
    press "j"
    press "j"
    assert_selector "[data-selected]"

    click_link "Open"
    assert_current_path(/state=open/)
    assert_no_selector "[data-selected]"
  end

  # Turbo swaps the new rows in and then waits a frame or two before it says
  # it has rendered. Clearing the cursor on that announcement undid any key
  # pressed in between — on rows that were already on screen. A person sees
  # the results and presses J; a moment later the cursor is gone.
  #
  # Pressed from a MutationObserver, which runs as the rows land and before
  # Turbo's announcement, so the window is hit every time rather than by luck.
  test "a key pressed as the new rows appear is not undone a moment later" do
    visit root_path
    execute_script(<<~JS)
      const frame = document.getElementById("ticket_list")
      frame.querySelectorAll("[data-shortcuts-target='row']").forEach((row) => row.dataset.stale = "")
      new MutationObserver((_, observer) => {
        if (frame.querySelector("[data-stale]") || !frame.querySelector("[data-shortcuts-target='row']")) return
        observer.disconnect()
        document.body.dispatchEvent(new KeyboardEvent("keydown", { key: "j", bubbles: true }))
        addEventListener("turbo:frame-render", () => document.body.dataset.announced = "", { once: true })
      }).observe(frame, { childList: true, subtree: true })
    JS

    click_link "All"
    assert_selector "body[data-announced]"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"
  end

  # The legend is fixed to the bottom-left corner and the footer keeps the
  # version and the revision there. It stays up until put away, so the footer
  # moves rather than sitting underneath it.
  test "the footer makes room for the legend rather than sitting under it" do
    visit root_path
    before = footer_padding_bottom

    press "?"
    assert_selector "[data-shortcuts-target='hint']", visible: true
    assert_operator footer_padding_bottom, :>, before

    press "?"
    assert_no_selector "[data-shortcuts-target='hint']", visible: true
    assert_equal before, footer_padding_bottom
  end

  test "escape empties the box and gives the list back" do
    visit root_path
    fill_in "q", with: "smtp_tls"
    assert_current_path(/q=smtp_tls/)

    find_field("q").send_keys(:escape)

    assert_equal "", find_field("q").value
    assert_no_current_path(/q=/)
  end

  # Clearing is not leaving — you may be about to type a different question.
  # Escape in an empty box is: it lets go, and the keys are the list's again.
  test "escape in an empty search box puts it down" do
    visit root_path
    fill_in "q", with: "smtp_tls"
    assert_list_answers "smtp_tls"

    find_field("q").send_keys(:escape)
    assert_list_answers nil
    assert_selector "input#q:focus"

    find_field("q").send_keys(:escape)
    assert_no_selector "input#q:focus"

    press "j"
    assert_selector "a[data-selected][data-ticket-id='#{@ticket.id}']"
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

  # Waits for the list to be the answer to `query` — nil for no query at all —
  # before a key is pressed on it.
  #
  # The URL can't say that: Turbo advances it a moment before the new rows
  # render. Nor can the rows merely having changed: when typing outpaces the
  # debounce, the answer to part of the word lands first, and a key pressed on
  # it is reset when the answer to the whole word replaces it, as a new list
  # should. The chip quoting the query is inside the frame, so it changes
  # exactly when the answer does.
  def assert_list_answers(query)
    within("turbo-frame#ticket_list") do
      query ? assert_text("“#{query}”") : assert_no_text("“")
    end
  end

  # What a `broadcast_refresh` makes the browser do, without the cable: the
  # test adapter delivers nothing, and this is the call Turbo's stream action
  # ends in — a morph of the current page.
  def refresh_like_a_broadcast
    execute_script("Turbo.session.refresh(document.baseURI)")
  end

  def footer_padding_bottom
    evaluate_script("parseFloat(getComputedStyle(document.querySelector('footer')).paddingBottom)")
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

  # Stands in for the operating system's light/dark setting. Change events fire
  # as they would for the real thing, so a page already open sees it flip.
  # An empty value hands the setting back to the browser.
  def emulate_color_scheme(value)
    page.driver.browser.execute_cdp("Emulation.setEmulatedMedia",
      features: [{name: "prefers-color-scheme", value: value}])
  end

  def fill_in_notes(text)
    field = find("[data-notes-target='field']")
    field.set(text)
    # Blur flushes the debounce rather than waiting it out.
    find("h1").click
  end
end
