# frozen_string_literal: true

require "test_helper"
require_relative "../../support/fake_tuber_job"

# What happens to a message on spool.inbound once ingest has run, and above all
# once it keeps failing.
#
# Nothing is ever buried. A buried job can only be seen by asking tuber, and one
# buried on spool.maintenance stopped inbound mail for six weeks without anyone
# asking. The mail itself is still in the mailbox — Spool never writes to it —
# so giving up on a job loses nothing: it leaves a DroppedMail row saying what
# to look for and where to rewind the poller to, and the header shows it.
class Ingest::InboundConsumerTest < ActiveSupport::TestCase
  RECEIVED_AT = "2026-08-10T23:14:22Z"

  test "a message that ingests is deleted" do
    job = inbound_job(:new_ticket)

    consume(job)

    assert_equal :deleted, job.outcome
    assert Message.exists?(message_id: "<CAF1a2b3c4d5@mail.example.com>")
  end

  test "a failure is released for a retry" do
    job = inbound_job(:new_ticket)

    failing_ingest { consume(job) }

    assert_equal :released, job.outcome
    assert_empty DroppedMail.all
  end

  test "a message that keeps failing is deleted, never buried, and recorded" do
    job = inbound_job(:new_ticket, releases: Ingest::TubeConsumer::MAX_RETRIES)

    failing_ingest { consume(job) }

    assert_equal :deleted, job.outcome

    dropped = DroppedMail.failed.sole
    assert_equal "<CAF1a2b3c4d5@mail.example.com>", dropped.message_id
    assert_equal "ada@example.com", dropped.from_email
    assert_equal "Printer catches fire when printing", dropped.subject
    assert_match "database is locked", dropped.reason
    # Fastmail's receivedAt, which is what the poller's cursor is kept in, not
    # the sender's Date header.
    assert_equal Time.iso8601(RECEIVED_AT), dropped.received_at
  end

  test "a job body that won't parse is deleted and recorded, never buried" do
    job = FakeTuberJob.new("not json")

    consume(job)

    assert_equal :deleted, job.outcome
    assert_match "JSON::ParserError", DroppedMail.failed.sole.reason
  end

  private

  def inbound_job(fixture, releases: 0)
    raw = file_fixture("emails/#{fixture}.eml").read
    body = {raw: Base64.strict_encode64(raw), source: "jmap", received_at: RECEIVED_AT}
    FakeTuberJob.new(body, releases: releases)
  end

  def consume(job)
    Ingest::InboundConsumer.new.send(:process_batch, [job])
  end

  def failing_ingest(&block)
    stubbing(Ingest::Inbound, :ingest, ->(*, **) { raise ActiveRecord::StatementTimeout, "database is locked" }, &block)
  end
end
