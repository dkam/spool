# frozen_string_literal: true

require "test_helper"

# A reply the customer's server accepted and failed later comes back to the
# support mailbox as a delivery-status report. LoopGuard still turns it away
# — it isn't correspondence — but the reply it's about must stop saying
# "Sent to customer". Driven through Ingest::Inbound, the way the poller
# hands it over.
class Ingest::BounceTest < ActiveSupport::TestCase
  # The Message-ID the bounce fixtures carry in their returned original.
  BOUNCED_ID = "<4d1f9c2e-7b3a-4e8d-9f61-2c5a8b0e1d77@spool.test>"
  # An earlier reply, which bounce_for_reply.eml's returned References name.
  EARLIER_ID = "<a0b1c2d3-1111-4222-8333-444455556666@spool.test>"

  setup do
    customer = Customer.create!(email: "dana@fieldworks.test", name: "Dana Whitmore")
    @sent_at = Time.zone.parse("2026-11-24T03:14:57Z")
    @ticket = Ticket.create!(customer: customer, subject: "Export button does nothing",
      state: "pending", last_activity_at: @sent_at)
  end

  test "a bounce for one of our replies marks it not delivered and brings the ticket back" do
    earlier = reply(EARLIER_ID, sent_at: @sent_at - 1.day)
    bounced = reply(BOUNCED_ID)

    result = nil
    assert_no_difference ["Message.count", "Ticket.count", "Customer.count"] do
      result = ingest(:bounce_for_reply)
    end

    # Still not a ticket of its own.
    assert result.rejected?

    bounced.reload
    assert bounced.undeliverable?
    assert_equal "Bounced by mx.fieldworks.test: 550 5.1.1 <dana@fieldworks.test>: " \
      "Recipient address rejected: User unknown in virtual mailbox table", bounced.delivery_error
    # When the report arrived, by its Date: header.
    assert_equal Time.zone.parse("2026-11-24T03:15:02Z"), bounced.delivery_failed_at
    # It did leave: the relay took it, and that time stays true.
    assert_not_nil bounced.delivered_at

    @ticket.reload
    assert_equal "open", @ticket.state
    assert @ticket.tagged?(Tag::UNDELIVERABLE)
    assert_equal bounced.delivery_failed_at, @ticket.last_activity_at

    # Matched on the original's Message-ID, never on its References.
    assert_not earlier.reload.undeliverable?

    assert_equal "bounce for reply #{bounced.id} on ticket ##{@ticket.id}", DroppedMail.rejected.sole.reason
  end

  test "a bounce returning the whole original is read the same way" do
    bounced = reply(BOUNCED_ID)

    assert ingest(:bounce_full_original).rejected?

    bounced.reload
    assert bounced.undeliverable?
    # No Remote-MTA in this one, so no "by".
    assert_equal "Bounced: 550 5.4.1 Recipient address rejected: Access denied. " \
      "[SY4PR01MB1234.ausprd01.prod.outlook.example]", bounced.delivery_error
    assert @ticket.reload.tagged?(Tag::UNDELIVERABLE)
  end

  test "a delay warning changes nothing" do
    pending = reply(BOUNCED_ID)

    assert ingest(:bounce_delayed).rejected?

    assert_not pending.reload.undeliverable?
    assert_nil pending.delivery_error
    @ticket.reload
    assert_equal "pending", @ticket.state
    assert_not @ticket.tagged?(Tag::UNDELIVERABLE)
    assert_match(/auto-submitted/, DroppedMail.rejected.sole.reason)
  end

  test "a bounce for mail Spool didn't send is an ordinary rejection" do
    # An agent writing from the mailbox by hand gets their own bounces; and
    # a customer's message with that id is still not one of our replies.
    Message.create!(ticket: @ticket, direction: "inbound", message_id: BOUNCED_ID,
      from_email: "dana@fieldworks.test", sent_at: @sent_at, body: JSON.generate({"text" => "Hi", "html" => nil}))

    assert ingest(:bounce_for_reply).rejected?

    assert_empty Message.where.not(delivery_failed_at: nil)
    assert_equal "pending", @ticket.reload.state
    assert_match(/auto-submitted/, DroppedMail.rejected.sole.reason)
  end

  test "the same bounce read again doesn't reopen a ticket closed since" do
    bounced = reply(BOUNCED_ID)
    ingest(:bounce_for_reply)
    failed_at = bounced.reload.delivery_failed_at

    # An agent dealt with it; then a rewind reads the mailbox again.
    @ticket.update!(state: "closed")
    assert ingest(:bounce_for_reply).rejected?

    assert_equal "closed", @ticket.reload.state
    assert_equal failed_at, bounced.reload.delivery_failed_at
    assert_equal "bounce for reply #{bounced.id} on ticket ##{@ticket.id}", DroppedMail.rejected.sole.reason
  end

  private

  def reply(message_id, sent_at: @sent_at)
    Message.create!(
      ticket: @ticket,
      direction: "outbound",
      message_id: message_id,
      subject: "Re: Export button does nothing [##{@ticket.id}]",
      sent_at: sent_at,
      delivered_at: sent_at + 1.second,
      body: JSON.generate({"text" => "It's fixed in the next release.", "html" => nil})
    )
  end

  def ingest(fixture)
    Ingest::Inbound.ingest(Rails.root.join("test/fixtures/files/emails/#{fixture}.eml").read, source: "test")
  end
end
