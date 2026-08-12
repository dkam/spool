require "application_system_test_case"

# The README's screenshots, generated rather than curated:
#
#   SCREENSHOTS=1 bin/rails test test/system/screenshots_test.rb
#
# Skipped otherwise, because CI has no use for it and a screen shot that
# changes on every run is noise in the diff. It lives here rather than in a
# script because the seeds plus a headless browser plus a booted app is exactly
# what a system test already is.
#
# The pictures come from db/seeds.rb, so the README shows the same worked
# example the design was drawn against (docs/ui.md) — and updating the seeds
# updates the README.
class ScreenshotsTest < ApplicationSystemTestCase
  IMAGES = Rails.root.join("docs/images")

  # The seeds are a few hundred writes, and loading them inside the suite's
  # uncommitted transaction intermittently raised SQLite3::BusyException — a
  # read transaction cannot always be promoted to a write one. Nothing here
  # needs the rollback anyway, so this test commits and cleans up after itself.
  self.use_transactional_tests = false

  TABLES = [MessageAttachment, Attachment, Message, TicketRead, Ticket, Customer, Template, Agent].freeze

  setup do
    skip "set SCREENSHOTS=1 to regenerate docs/images" unless ENV["SCREENSHOTS"]

    # Seeds are written to be idempotent and to key on natural keys, so they
    # can be loaded straight into the test database.
    ApplicationRecord.writing { load Rails.root.join("db/seeds.rb") }
    FileUtils.mkdir_p(IMAGES)
  end

  teardown do
    ApplicationRecord.writing { TABLES.each(&:delete_all) } if ENV["SCREENSHOTS"]
  end

  test "the screens" do
    dana = Ticket.joins(:customer).find_by(customers: {email: "dana@fieldworks.co"},
      subject: "Can't connect SMTP after upgrade to 2.4")

    visit root_path
    assert_text "Tickets"
    shoot "tickets-list"

    visit ticket_path(dana)
    assert_text "dana@fieldworks.co"
    shoot "ticket-thread"

    visit customer_path(dana.customer)
    assert_text "Dana Whitmore"
    shoot "customer"

    # Search and dark share a shot: search narrows the list rather than opening
    # a screen of its own, so a narrowed list is all there is to show, and the
    # theme is one attribute on <html> rather than a different design.
    visit root_path
    fill_in "q", with: "dana"
    # Wait for the narrowed list rather than for any list: the frame still
    # holds the unfiltered rows until the search comes back.
    assert_no_text "Refund for duplicate invoice"
    click_button "Dark"
    assert_selector "html[data-theme='dark']"
    shoot "search-dark"
  end

  private

  # Capybara's window is 1280×900 minus the browser's own chrome, and a long
  # thread runs past it. Ask the page how tall it actually is and resize to
  # match, so the shot is the whole screen rather than the top of it.
  def shoot(name)
    height = evaluate_script("document.documentElement.scrollHeight").to_i
    page.driver.browser.manage.window.resize_to(1280, [height + 80, 2400].min)
    sleep 0.2 # let the layout settle after the resize before the shutter
    # The bytes rather than Capybara's `save_screenshot`, which Standard reads
    # as a debugger call left behind in a test — which, everywhere else, it is.
    File.binwrite(IMAGES.join("#{name}.png"), page.driver.browser.screenshot_as(:png))
    page.driver.browser.manage.window.resize_to(1280, 900)
  end
end
