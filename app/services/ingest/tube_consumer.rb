# frozen_string_literal: true

module Ingest
  # Loop, connection and shutdown plumbing shared by every tuber consumer.
  # Subclasses implement #process_batch(jobs). See docs/queue.md.
  class TubeConsumer
    DEFAULT_BATCH_SIZE = 10
    RETRY_DELAY = 5

    # When the tube is empty, long-poll the reserve for this long (the server
    # parks the waiter) rather than hot-looping. The timeout bounds the park so
    # the loop still wakes periodically to honour the stop flag.
    RESERVE_TIMEOUT = 30

    # Bury rather than release once a job has been retried this many times, so
    # a poison-pill message doesn't cycle on the tube forever. A buried job is
    # visible in tuber's stats and can be kicked back once the bug is fixed —
    # which is the point: silently dropping a customer's email is worse.
    MAX_RETRIES = 5

    # A job's TTR is the server's "is this worker still alive?" timer. Hold a
    # job past its TTR without touching it and tuber assumes the worker died and
    # hands the job to someone else — while this worker is still working on it.
    # Touching early is free; touching late means duplicate processing.
    TOUCH_INTERVAL = 30

    # Seconds between attempts to (re)connect. A worker retries for as long as
    # it takes: on boot it waits for tuber to come up, and after a tuber restart
    # it reconnects and re-watches. A worker with no live queue has nothing to
    # do but wait, so crashing out gains nothing.
    CONNECT_RETRY_INTERVAL = 2

    attr_reader :tube, :batch_size

    def initialize(tube:, batch_size: DEFAULT_BATCH_SIZE)
      @tube = tube
      @batch_size = batch_size
      @stop = false
    end

    def stop!
      @stop = true
    end

    def run
      # connect! opens the connection and WATCHes on the same thread that
      # reserves. Beaneater connections are per-thread: a watch issued on
      # another thread wouldn't apply to the socket this thread reserves on,
      # and the worker would silently reserve from `default` (always empty) and
      # never drain its tube.
      return unless connect_with_retry

      until @stop
        begin
          process_one_batch
        rescue *Tuber::CONNECTION_ERRORS => e
          # Tuber went away mid-loop. Rebuild the connection (which re-WATCHes)
          # and carry on; in-flight jobs are re-reserved after their TTR.
          log_exception("[#{self.class.name}] tuber connection lost, reconnecting", e)
          break unless reconnect
        rescue => e
          log_exception("[#{self.class.name}] loop error (continuing)", e)
          sleep 1
        end
      end
    ensure
      close_client
    end

    def process_one_batch
      jobs = reserve_batch
      return if jobs.empty?

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      keeping_alive(jobs) do
        # executor.wrap is what a Rails request gets for free and a bare worker
        # thread does not: it returns database connections to the pool at the
        # end of each batch, and keeps code reloading coherent in development.
        # Without it a consumer thread holds its connection for the life of the
        # process, and with a small writer pool the other consumers never get
        # one.
        Rails.application.executor.wrap do
          # Consumers also run outside the DatabaseSelector middleware, so
          # without this every write would hit the reading role and raise
          # ActiveRecord::ReadOnlyError.
          ApplicationRecord.writing { process_batch(jobs) }
        end
      end
      ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
      Rails.logger.info "[#{self.class.name}] processed #{jobs.size} in #{ms}ms"
    end

    # Run the block with a heartbeat touching `jobs`, so a batch slower than its
    # TTR keeps the reservations it's still working on.
    #
    # The heartbeat shares this consumer's connection deliberately: a
    # reservation belongs to the connection that made it, so a touch from any
    # other socket is NOT_FOUND. Beaneater serialises commands on that
    # connection's mutex, and nothing reserves while a batch is in flight, so
    # the touch only ever contends with this batch's own deletes.
    def keeping_alive(jobs)
      # A queue rather than a flag plus sleep: pop(timeout:) waits the full
      # interval but wakes the instant the batch finishes, so `ensure` never
      # blocks waiting out a nap.
      finished = Queue.new
      heartbeat = Thread.new do
        until finished.pop(timeout: touch_interval)
          jobs.each do |job|
            job.touch
          rescue
            # Already deleted, expired, or never reserved — nothing left to keep
            # alive. process_batch owns the job's fate; a failed touch is only
            # ever a lost cause, never a new problem.
            nil
          end
        end
      end
      yield
    ensure
      finished&.push(true)
      # join, not kill: killing mid-touch would abandon a half-written command
      # on the shared socket and desync the protocol for every later reserve.
      heartbeat&.join(TOUCH_INTERVAL)
    end

    # Overridable so tests can drive the heartbeat without waiting on the wall
    # clock. A subclass can't just redefine TOUCH_INTERVAL — Ruby resolves
    # constants lexically, so the reference above would still find this class's.
    def touch_interval = TOUCH_INTERVAL

    private

    def connect_with_retry
      attempt = 0
      until @stop
        begin
          @client = Tuber.consumer_client
          @client.tubes.watch!(@tube)
          Rails.logger.info "[#{self.class.name}] watching #{@tube}"
          return true
        rescue => e
          attempt += 1
          Rails.logger.warn "[#{self.class.name}] waiting for tuber (attempt #{attempt}): #{e.class}: #{e.message}"
          interruptible_sleep(CONNECT_RETRY_INTERVAL)
        end
      end
      false
    end

    def reconnect
      close_client
      connect_with_retry
    end

    def close_client
      @client&.close
    rescue
      # A dead socket can raise on close; we only care that it's released.
    ensure
      @client = nil
    end

    # Sleep in one-second slices so a SIGTERM (which sets @stop) breaks the wait
    # promptly instead of blocking a full interval.
    def interruptible_sleep(seconds)
      remaining = seconds
      while remaining > 0 && !@stop
        sleep 1
        remaining -= 1
      end
    end

    # One blocking call: long-poll for the first job, then drain every sibling
    # that's ready up to batch_size. An empty tube parks the waiter server-side
    # and returns an empty batch, so the loop wakes to honour @stop.
    def reserve_batch
      @client.tubes.reserve_batch(@batch_size, RESERVE_TIMEOUT)
    end

    # Override.
    def process_batch(jobs)
      raise NotImplementedError
    end

    def safe_finalize(job, outcome)
      case outcome
      when :ok then job.delete
      when :retry then bury_or_release(job)
      end
    rescue Beaneater::NotFoundError
      # Already gone server-side — nothing to do.
    end

    def bury_or_release(job)
      releases = begin
        job.stats.releases.to_i
      rescue
        0
      end

      if releases >= MAX_RETRIES
        Rails.logger.error "[#{self.class.name}] burying job after #{releases} retries"
        job.bury
      else
        job.release(delay: RETRY_DELAY)
      end
    end

    def log_exception(prefix, e)
      Rails.logger.error "#{prefix}: #{e.class}: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
    end
  end
end
