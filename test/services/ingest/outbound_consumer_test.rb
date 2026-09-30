# frozen_string_literal: true

require "test_helper"
require_relative "../../support/fake_tuber_job"

# What happens to a send on spool.outbound once it has failed.
#
# Nothing is ever buried. A buried job holds its `idp:outbound-<id>` key, so
# `bin/rails outbound:backfill` could never queue that reply again. Dropping the
# job loses nothing: the reply is a row with no delivered_at, the thread shows
# it undelivered, the header counts it, and backfill sends it once the cause is
# fixed.
class Ingest::OutboundConsumerTest < ActiveSupport::TestCase
  setup do
    customer = Customer.create!(email: "dana@fieldworks.co", name: "Dana Whitmore")
    agent = Agent.create!(oidc_sub: "agent-1", email: "sam@spool.test", name: "Sam")
    ticket = Ticket.create!(customer: customer, subject: "Outbox stuck", state: "open", last_activity_at: 1.hour.ago)
    @reply = Message.compose!(ticket: ticket, agent: agent, text: "Try turning it off and on.")
  end

  test "a send the transport rejects is deleted, not buried, and stays undelivered" do
    job = outbound_job(@reply.id)

    delivering(->(*, **) { raise Outbound::Smtp::Rejected, "550 5.1.1 no such user" }) { consume(job) }

    assert_equal :deleted, job.outcome
    assert_nil @reply.reload.delivered_at
  end

  test "a send that fails is released for a retry" do
    job = outbound_job(@reply.id)

    delivering(->(*, **) { raise Net::OpenTimeout }) { consume(job) }

    assert_equal :released, job.outcome
  end

  test "a send that keeps failing is deleted, never buried" do
    job = outbound_job(@reply.id, releases: Ingest::TubeConsumer::MAX_RETRIES)

    delivering(->(*, **) { raise Net::OpenTimeout }) { consume(job) }

    assert_equal :deleted, job.outcome
    assert_nil @reply.reload.delivered_at
  end

  test "a job for a message that no longer exists is deleted, not buried" do
    job = outbound_job(0)

    consume(job)

    assert_equal :deleted, job.outcome
  end

  private

  def outbound_job(message_id, releases: 0)
    FakeTuberJob.new({message_id: message_id}, releases: releases)
  end

  def consume(job)
    Ingest::OutboundConsumer.new.send(:process_batch, [job])
  end

  def delivering(replacement, &block)
    stubbing(Outbound::Delivery, :deliver!, replacement, &block)
  end
end
