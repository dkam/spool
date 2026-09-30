# frozen_string_literal: true

module Ingest
  # Drains a tube whose bodies look like `{ "class": "Foo::BarJob", "args": [] }`,
  # instantiates the class and calls #perform(*args). Used for spool.maintenance,
  # where bin/scheduler pushes the recurring jobs from config/schedule.yml.
  #
  # These are plain classes, not ActiveJob subclasses — the scheduler names them
  # by string and there's no serialisation to negotiate.
  #
  # A failed job is deleted, not retried and never buried. The schedule is the
  # retry: the next tick runs the same job with the same (empty) arguments, so a
  # release buys nothing. Burying is actively harmful. Tuber keeps a buried
  # job's `idp:` key live, so every later put with that key is suppressed as a
  # duplicate of the dead job. That is how one Fastmail outage buried
  # Jmap::PollJob and stopped inbound mail for six weeks while the scheduler
  # kept logging that it was firing it.
  class DispatchConsumer < TubeConsumer
    def initialize(tube:, batch_size: 5)
      super
    end

    private

    def process_batch(jobs)
      jobs.each do |job|
        klass_name = nil
        body = JSON.parse(job.body)
        klass_name = body["class"]
        args = body["args"] || []

        klass_name.constantize.new.perform(*args)
        job.delete
      rescue ::Tuber::NotFoundError
        nil
      rescue => e
        log_exception("[DispatchConsumer] #{klass_name || "?"} failed", e)
        # Deleted like a success; the next tick is the retry. See above.
        safe_finalize(job, :ok)
      end
    end
  end
end
