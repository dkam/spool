# frozen_string_literal: true

require "test_helper"
require "rake"

# `bin/rails outbound:backfill` — queues every reply still waiting to go.
class OutboundRakeTest < ActiveSupport::TestCase
  SMTP = {"SMTP_ADDRESS" => "smtp.example.com", "SPOOL_MAILBOX" => "support@example.com"}.freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("outbound:backfill")

    agent = Agent.create!(oidc_sub: "agent-1", email: "sam@spool.test", name: "Sam")
    ticket = Ticket.create!(customer: Customer.create!(email: "dana@fieldworks.co"),
      subject: "Outbox", state: "open", last_activity_at: 1.hour.ago)

    @waiting = Message.compose!(ticket: ticket, agent: agent, text: "Waiting.")
    @delivered = Message.compose!(ticket: ticket, agent: agent, text: "Went.")
    @delivered.update!(delivered_at: Time.current)
    @refused = Message.compose!(ticket: ticket, agent: agent, text: "Refused.")
    @refused.update!(delivery_failed_at: Time.current, delivery_error: "550 5.1.1 User unknown")
  end

  # Queueing a refused reply sends it straight back to the address that
  # refused it — and one an agent gave up on is one they decided not to send.
  test "queues the replies still waiting, and none that will never go" do
    queued = []

    with_env(SMTP) do
      stubbing(Outbound::Delivery, :enqueue, ->(message) { queued << message }) do
        assert_output(/Queueing 1 /) do
          Rake::Task["outbound:backfill"].reenable
          Rake::Task["outbound:backfill"].invoke
        end
      end
    end

    assert_equal [@waiting], queued
  end
end
