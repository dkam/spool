# frozen_string_literal: true

require "test_helper"

class MessageComposeTest < ActiveSupport::TestCase
  setup do
    @agent = Agent.create!(oidc_sub: "sub-1", email: "agent@example.com", name: "Agent Smith")
    @customer = Customer.create!(email: "ada@example.com")
    @ticket = Ticket.create!(customer: @customer, subject: "Printer", last_activity_at: 2.hours.ago)

    @inbound = Message.create!(
      ticket: @ticket, direction: "inbound",
      message_id: "<customer-1@example.com>",
      references_header: "<older@example.com>",
      sent_at: 2.hours.ago, body: JSON.generate({"text" => "help", "html" => nil})
    )
  end

  test "an outbound reply threads onto the last emailed message" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "We are looking into it.")

    assert_equal "outbound", message.direction
    assert_equal @agent, message.agent
    assert_equal "<customer-1@example.com>", message.in_reply_to
    assert_equal "<older@example.com> <customer-1@example.com>", message.references_header
    assert_match(/\A<[0-9a-f-]{36}@/, message.message_id)
    assert_equal "We are looking into it.", message.reload.body_text
    assert_equal "We are looking into it.", message.body_excerpt
  end

  test "an outbound reply flips the ticket to pending" do
    Message.compose!(ticket: @ticket, agent: @agent, text: "Looking into it.")

    @ticket.reload
    assert_equal "pending", @ticket.state
    assert_operator @ticket.last_activity_at, :>, 1.minute.ago
  end

  test "the subject carries the ticket tag so a reply can be re-threaded" do
    message = Message.compose!(ticket: @ticket, agent: @agent, text: "Hello")

    assert_equal "Printer [##{@ticket.id}]", message.subject
  end

  test "a note carries no threading headers and does not change state" do
    @ticket.update!(state: "open")

    note = Message.compose!(ticket: @ticket, agent: @agent, text: "Customer is a VIP",
      direction: "note")

    assert note.note?
    assert_nil note.in_reply_to
    assert_nil note.references_header
    assert_equal "open", @ticket.reload.state
  end

  test "a reply threads onto the last emailed message, not the last note" do
    Message.compose!(ticket: @ticket, agent: @agent, text: "internal", direction: "note")

    reply = Message.compose!(ticket: @ticket, agent: @agent, text: "external")

    assert_equal "<customer-1@example.com>", reply.in_reply_to
  end

  test "consecutive replies chain their references" do
    first = Message.compose!(ticket: @ticket, agent: @agent, text: "one")
    Message.create!(ticket: @ticket, direction: "inbound", message_id: "<customer-2@example.com>",
      in_reply_to: first.message_id, references_header: first.reply_references,
      sent_at: Time.current, body: JSON.generate({"text" => "thanks", "html" => nil}))

    second = Message.compose!(ticket: @ticket, agent: @agent, text: "two")

    assert_equal "<customer-2@example.com>", second.in_reply_to
    assert_includes second.references_header, first.message_id
    assert_includes second.references_header, "<customer-2@example.com>"
  end

  test "generated message ids are unique and use a domain Spool controls" do
    ids = 5.times.map { Message.generate_message_id(domain: "spool.test") }

    assert_equal 5, ids.uniq.size
    assert ids.all? { |id| id.end_with?("@spool.test>") }
  end

  test "a composed outbound message is recognised if it is echoed back" do
    sent = Message.compose!(ticket: @ticket, agent: @agent, text: "Our reply")

    echoed = <<~EML
      Message-ID: #{sent.message_id}
      Date: Tue, 11 Aug 2026 20:00:00 +1000
      From: Support <support@spool.test>
      To: Ada <ada@example.com>
      Subject: #{sent.subject}
      Content-Type: text/plain; charset=UTF-8

      Our reply
    EML

    result = Ingest::Inbound.ingest(echoed)

    assert result.rejected?
    assert_match(/own outbound/, result.reason)
  end

  test "refuses to compose an inbound message" do
    assert_raises(ArgumentError) do
      Message.compose!(ticket: @ticket, agent: @agent, text: "x", direction: "inbound")
    end
  end
end
