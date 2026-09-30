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

    # Give up on a job once it has been retried this many times, so a
    # poison-pill message doesn't cycle on the tube forever.
    #
    # Giving up means reporting it and deleting it — never burying. A buried job
    # is visible only to someone who asks tuber, and it keeps its `idp:` key
    # live, so every later put with that key is swallowed as a duplicate. That
    # is how one buried poll stopped inbound mail for six weeks. Nothing is lost
    # by deleting instead: every job here is a pointer to something that
    # survives it — the mail is still in the mailbox, the reply is still an
    # undelivered row — and each consumer's #gave_up records what to recover.
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
      # reserves. Client connections are per-thread: a watch issued on
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
    # other socket is NOT_FOUND. The client serialises commands on that
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

    # :ok deletes the job. :retry releases it for another attempt, or gives up
    # on it once MAX_RETRIES is reached. :give_up gives up now, for a failure
    # no retry will change.
    def safe_finalize(job, outcome, error = nil)
      case outcome
      when :ok then job.delete
      when :retry then retry_or_give_up(job, error)
      when :give_up then give_up(job, error)
      end
    rescue ::Tuber::NotFoundError
      # Already gone server-side — nothing to do.
    end

    def retry_or_give_up(job, error)
      releases = begin
        job.stats.releases.to_i
      rescue
        0
      end

      if releases >= MAX_RETRIES
        give_up(job, error)
      else
        job.release(delay: RETRY_DELAY)
      end
    end

    # Record, report, delete. The delete happens even when recording fails: a
    # job left reserved comes back after its TTR and fails again forever, and
    # the exception has already been reported.
    def give_up(job, error)
      Rails.logger.error "[#{self.class.name}] giving up on job #{job_id(job)}"
      begin
        gave_up(job, error)
      rescue => e
        log_exception("[#{self.class.name}] couldn't record the job it gave up on", e)
      end
      Sentry.capture_message("[#{self.class.name}] gave up on a job",
        level: :error, tags: {consumer: self.class.name},
        extra: {error: error && "#{error.class}: #{error.message}"})
      job.delete
    end

    # Override to record what was lost when a job is given up on.
    def gave_up(job, error) = nil

    def job_id(job)
      job.id
    rescue
      "?"
    end

    # Every consumer failure comes through here — the loop's own rescues and
    # each subclass's per-job one — which is the only reason a single
    # capture_exception covers the workers.
    #
    # They need it explicitly. Sentry sees a web exception because it is in the
    # Rack middleware stack; a worker thread has no middleware, and a consumer
    # that swallows an exception to keep draining the tube would otherwise fail
    # in complete silence. A no-op when SENTRY_DSN is unset.
    def log_exception(prefix, e)
      Rails.logger.error "#{prefix}: #{e.class}: #{e.message}"
      Rails.logger.error e.backtrace.first(10).join("\n")
      Sentry.capture_exception(e, tags: {consumer: self.class.name})
    end
  end
end
