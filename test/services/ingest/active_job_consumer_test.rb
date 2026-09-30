# frozen_string_literal: true

require "test_helper"
require_relative "../../support/fake_tuber_job"

class Ingest::ActiveJobConsumerTest < ActiveSupport::TestCase
  # Nothing reads spool.activejob's buried count, so a buried job there would
  # be gone as surely as a deleted one — just without the report. Retries, then
  # the report and the delete.
  test "a job that keeps failing is deleted, never buried" do
    job = FakeTuberJob.new({activejob: {"job_class" => "NoSuchJob"}}, releases: Ingest::TubeConsumer::MAX_RETRIES)

    Ingest::ActiveJobConsumer.new.send(:process_batch, [job])

    assert_equal :deleted, job.outcome
  end
end
