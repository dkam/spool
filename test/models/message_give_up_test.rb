# frozen_string_literal: true

require "test_helper"

# Message#give_up_delivery! — an agent deciding a stuck reply is never going
# to go, for whatever reason (an address the classifier didn't recognise as
# bad, a test send, a reply that's stale by now). Unlike a refusal, it is a
# decision rather than news, so it leaves the ticket where the agent put it.
class MessageGiveUpTest < ActiveSupport::TestCase
  setup do
    @customer = Customer.create!(email: "dana@fieldworks.co")
    @agent = Agent.create!(oidc_sub: "agent-1", email: "sam@spool.test", name: "Sam")
    @ticket = Ticket.create!(customer: @customer, subject: "Outbox", state: "open", last_activity_at: 1.hour.ago)
  end

  test "stamps the reply undeliverable, signed by the agent, and keeps the last error" do
    reply = Message.compose!(ticket: @ticket, agent: @agent, text: "Hello?")
    reply.update!(delivery_error: "SMTP refused: Net::SMTPFatalError: 550 no such user")
    @ticket.update!(state: "closed")

    reply.give_up_delivery!(agent: @agent)

    reply.reload
    assert reply.undeliverable?
    assert_not reply.awaiting_delivery?
    assert_equal "Given up by Sam. Last attempt: SMTP refused: Net::SMTPFatalError: 550 no such user", reply.delivery_error
    assert_equal "closed", @ticket.reload.state
    assert_not @ticket.tagged?(Tag::UNDELIVERABLE)
  end

  test "is no longer among the replies awaiting delivery" do
    stuck = Message.compose!(ticket: @ticket, agent: @agent, text: "Stuck.")
    other = Message.compose!(ticket: @ticket, agent: @agent, text: "Also stuck.")

    stuck.give_up_delivery!(agent: @agent)

    assert_equal [other], Message.awaiting_delivery.to_a
    assert_equal "Given up by Sam", stuck.reload.delivery_error
  end

  test "only a reply that is still waiting can be given up on" do
    delivered = Message.compose!(ticket: @ticket, agent: @agent, text: "Went.")
    delivered.update!(delivered_at: Time.current)
    note = Message.compose!(ticket: @ticket, agent: @agent, text: "Internal.", direction: "note")
    given_up = Message.compose!(ticket: @ticket, agent: @agent, text: "Gone.")
    given_up.give_up_delivery!(agent: @agent)

    [delivered, note, given_up].each do |message|
      assert_raises(Message::NotAwaitingDelivery) { message.give_up_delivery!(agent: @agent) }
    end
  end
end
