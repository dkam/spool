# frozen_string_literal: true

require "test_helper"

class TicketReadTest < ActiveSupport::TestCase
  setup do
    @alice = Agent.create!(oidc_sub: "sub-alice", email: "alice@example.com", name: "Alice")
    @bob = Agent.create!(oidc_sub: "sub-bob", email: "bob@example.com", name: "Bob")
    @customer = Customer.create!(email: "ada@example.com")
    @ticket = Ticket.create!(customer: @customer, subject: "Printer", last_activity_at: 1.hour.ago)
  end

  test "a never-opened ticket is unread" do
    assert @ticket.unread_for?(@alice)
    assert_includes Ticket.unread_for(@alice), @ticket
  end

  test "marking read clears it for that agent only" do
    @ticket.mark_read!(@alice)

    refute @ticket.unread_for?(@alice)
    assert_empty Ticket.unread_for(@alice)

    assert @ticket.unread_for?(@bob)
    assert_includes Ticket.unread_for(@bob), @ticket
  end

  test "new activity makes a read ticket unread again" do
    @ticket.mark_read!(@alice)
    refute @ticket.unread_for?(@alice)

    @ticket.record_inbound_activity!(Time.current)

    assert @ticket.unread_for?(@alice)
    assert_includes Ticket.unread_for(@alice), @ticket
  end

  test "marking read twice updates rather than duplicating" do
    @ticket.mark_read!(@alice)

    assert_no_difference "TicketRead.count" do
      @ticket.mark_read!(@alice)
    end
  end

  test "the scope and the predicate agree across a mixed set" do
    read = @ticket
    read.mark_read!(@alice)

    never_opened = Ticket.create!(customer: @customer, subject: "B", last_activity_at: 1.hour.ago)

    stale = Ticket.create!(customer: @customer, subject: "C", last_activity_at: 2.hours.ago)
    stale.mark_read!(@alice)
    stale.update!(last_activity_at: Time.current)

    scoped = Ticket.unread_for(@alice).to_a

    assert_equal [never_opened, stale].map(&:id).sort, scoped.map(&:id).sort
    Ticket.all.each do |ticket|
      assert_equal scoped.include?(ticket), ticket.unread_for?(@alice),
        "scope and predicate disagree on ticket #{ticket.id}"
    end
  end

  test "timestamps_for avoids a query per row" do
    @ticket.mark_read!(@alice)
    other = Ticket.create!(customer: @customer, subject: "B", last_activity_at: 1.hour.ago)

    timestamps = TicketRead.timestamps_for(@alice, [@ticket, other])

    assert_equal [@ticket.id], timestamps.keys
    assert_kind_of Time, timestamps[@ticket.id]
  end

  test "no agent means nothing is unread rather than everything" do
    refute @ticket.unread_for?(nil)
    assert_empty Ticket.unread_for(nil)
    assert_nil TicketRead.mark_read!(agent: nil, ticket: @ticket)
  end
end
