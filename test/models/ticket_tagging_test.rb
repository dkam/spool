require "test_helper"

# Tags and the one tag with behaviour. The scopes matter most: `tagged` /
# `not_tagged` are what hide spam from every list, and they have to compose
# with with_read_state_for's join without multiplying or dropping rows.
class TicketTaggingTest < ActiveSupport::TestCase
  setup do
    @customer = Customer.create!(email: "kathy@csszenith.com", name: "Kathy")
    @ticket = Ticket.create!(
      customer: @customer, subject: "Migrate to Webflow?",
      state: "open", last_activity_at: 5.minutes.ago
    )
  end

  test "tag! is idempotent and names are one tag regardless of case and spacing" do
    @ticket.tag!("Spam")
    @ticket.tag!(" spam ")

    assert_equal 1, Tag.count
    assert_equal ["spam"], @ticket.tags.map(&:name)
    assert @ticket.tagged?("SPAM")
  end

  test "untag! removes the tagging, keeps the tag, and ignores unknown names" do
    @ticket.tag!("spam")

    @ticket.untag!("spam")
    @ticket.untag!("never-existed")

    assert_equal [], @ticket.reload.tags.to_a
    assert Tag.exists?(name: "spam"), "the tag itself outlives its last use"
  end

  test "a tag change touches the ticket, because the row is the broadcast signal" do
    before = @ticket.updated_at
    travel 1.minute do
      @ticket.tag!("spam")
    end

    assert_operator @ticket.reload.updated_at, :>, before
  end

  test "tagged and not_tagged split on the one tag, not on having any tag" do
    other = Ticket.create!(customer: @customer, subject: "Another",
      state: "open", last_activity_at: 1.minute.ago)
    @ticket.tag!("spam")
    other.tag!("billing")

    assert_equal [@ticket], Ticket.tagged("spam").to_a
    assert_equal [other], Ticket.not_tagged("spam").to_a
  end

  test "the scopes compose with with_read_state_for" do
    agent = Agent.create!(oidc_sub: "a1", email: "sam@spool.test")
    @ticket.tag!("spam")

    rows = Ticket.with_read_state_for(agent).not_tagged("spam").to_a
    assert_equal [], rows

    rows = Ticket.with_read_state_for(agent).tagged("spam").to_a
    assert_equal [@ticket.id], rows.map(&:id)
    assert rows.first.unread?, "the joined read-state column must survive the tag join"
  end

  test "mark_spam! tags the ticket and blocks the customer; unmark_spam! undoes both" do
    @ticket.mark_spam!

    assert @ticket.spam?
    assert @customer.reload.blocked?

    @ticket.unmark_spam!

    assert_not @ticket.reload.spam?
    assert_not @customer.reload.blocked?
  end

  test "state is orthogonal: marking spam moves no ticket out of open" do
    @ticket.mark_spam!

    assert_equal "open", @ticket.reload.state
  end
end
