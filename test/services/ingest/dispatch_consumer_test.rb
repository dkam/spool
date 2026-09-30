# frozen_string_literal: true

require "test_helper"
require_relative "../../support/fake_tuber_job"

# What happens to a scheduled job once it has run, and above all once it has
# failed.
#
# Everything on spool.maintenance was put there by bin/scheduler, and the
# schedule already runs it again. The production incident this guards against:
# a Fastmail outage failed Jmap::PollJob five times, the consumer buried it, and
# tuber went on treating the buried job as the live holder of its `idp:jmap_poll`
# key. Every later put was suppressed as a duplicate, so the scheduler kept
# "firing" every minute and inbound mail stopped for six weeks with nothing in
# the logs after the burial.
class Ingest::DispatchConsumerTest < ActiveSupport::TestCase
  class SucceedingJob
    def perform = nil
  end

  class FailingJob
    def perform = raise(Net::OpenTimeout, "Failed to open TCP connection to api.fastmail.com:443")
  end

  def scheduled(klass, releases: 0)
    FakeTuberJob.new({"class" => klass.name, "args" => []}, releases: releases)
  end

  def dispatch(job)
    Ingest::DispatchConsumer.new(tube: "spool.maintenance").send(:process_batch, [job])
    job.outcome
  end

  test "a job that runs is deleted" do
    assert_equal :deleted, dispatch(scheduled(SucceedingJob))
  end

  # A retry would hold the idp key for its delay and do what the next tick does
  # anyway, so a failure is dropped straight away.
  test "a job that fails is deleted, not released for a retry" do
    assert_equal :deleted, dispatch(scheduled(FailingJob))
  end

  test "a job that keeps failing is deleted, never buried" do
    releases = Ingest::TubeConsumer::MAX_RETRIES

    assert_equal :deleted, dispatch(scheduled(FailingJob, releases: releases))
  end
end
