# frozen_string_literal: true

require "active_job/queue_adapters/abstract_adapter"

module ActiveJob
  module QueueAdapters
    # Puts Active Job payloads onto a single tuber tube. Ingest::ActiveJobConsumer
    # drains it and calls ActiveJob::Base.execute, which runs the job class
    # normally — mailers and any other deliver_later use this path.
    #
    # Job *queue names* are carried in the payload rather than mapped onto
    # separate tubes: Spool's Active Job volume is a handful of jobs a day, and
    # one tube with one consumer is easier to reason about than several. The
    # latency-sensitive work (inbound mail) doesn't go through Active Job at all
    # — it has its own tube and its own consumer.
    class TuberAdapter < AbstractAdapter
      def enqueue(job)
        ::Ingest::Tuber.put(::Ingest::Tuber::ACTIVEJOB_TUBE,
          {activejob: job.serialize, queue: job.queue_name})
      end

      def enqueue_at(job, timestamp)
        delay = (timestamp - Time.current.to_f).round
        delay = 0 if delay < 0
        ::Ingest::Tuber.put(::Ingest::Tuber::ACTIVEJOB_TUBE,
          {activejob: job.serialize, queue: job.queue_name},
          delay: delay)
      end
    end
  end
end
