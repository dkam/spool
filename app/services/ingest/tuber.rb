# frozen_string_literal: true

module Ingest
  # Thin wrapper over the `tuber` gem (../tuber-gem), covering connection
  # lifecycle, the put helper, and the liveness/depth probes. See docs/queue.md.
  #
  # This module and the gem share a name, and the gem's is at the top level, so
  # **every reference to the gem here must be written `::Tuber`**. A bare
  # `Tuber::NotFoundError` inside `module Ingest` resolves to
  # `Ingest::Tuber::NotFoundError` and raises NameError — and because Ruby
  # evaluates a `rescue` class only when something is actually raised, it would
  # do so from the error path, in production, having passed every test that
  # never made a connection die.
  module Tuber
    # Raw RFC822 handed over by the IMAP poller, one job per message.
    INBOUND_TUBE = "spool.inbound"

    # Outbound sends (SMTP or Mailgun). Separated from inbound so a provider outage
    # backing up sends can't stall ingestion.
    OUTBOUND_TUBE = "spool.outbound"

    # Recurring work pushed by bin/scheduler from config/schedule.yml.
    MAINTENANCE_TUBE = "spool.maintenance"

    # Everything enqueued through Active Job (deliver_later, perform_later).
    ACTIVEJOB_TUBE = "spool.activejob"

    ALL_TUBES = [INBOUND_TUBE, OUTBOUND_TUBE, ACTIVEJOB_TUBE, MAINTENANCE_TUBE].freeze

    # TTR covers one full message round trip: MIME parse, zstd compress, and
    # the SQLite write. Well under a second in practice; 120s leaves generous
    # headroom before tuber re-releases the job to another worker.
    DEFAULT_TTR = 120
    DEFAULT_PRI = 1024

    # A dead socket — the tuber server was restarted or bounced under us. The
    # client retries a few times inside a single command and then gives up with
    # NotConnected, at which point the cached connection holds a closed socket
    # that never heals on its own. Producers and consumers both key off this
    # list to rebuild the connection.
    CONNECTION_ERRORS = [
      ::Tuber::NotConnected, Errno::ECONNREFUSED, Errno::ECONNRESET,
      Errno::EPIPE, EOFError, IOError, SocketError
    ].freeze

    class << self
      def address
        ENV.fetch("TUBER_URL", "localhost:11300")
      end

      # One producer client per thread. The client serialises commands through
      # an internal mutex, but a per-thread connection avoids contending Puma
      # threads on the same socket.
      def producer
        Thread.current[:spool_tuber_producer] ||= ::Tuber.new(address)
      end

      # Throw the per-thread connection away so the next #producer rebuilds it.
      def reset_producer!
        Thread.current[:spool_tuber_producer]&.close
      rescue
        # Closing a dead socket can itself raise; we only care that it's gone.
      ensure
        Thread.current[:spool_tuber_producer] = nil
      end

      # Run a block against the per-thread producer, rebuilding the connection
      # once if it turns out to be dead. Lets producers survive a tuber restart:
      # one clean retry against a fresh connection, then the error propagates.
      # Fail fast, not a blocking wait — a web request must not hang on a down
      # queue.
      def with_producer
        tries = 0
        begin
          yield producer
        rescue *CONNECTION_ERRORS
          reset_producer!
          tries += 1
          retry if tries < 2
          raise
        end
      end

      # con: and idp: are tuber extensions (per-key concurrency cap and
      # idempotency suppression). Vanilla beanstalkd rejects unknown put
      # options, so callers omit them unless they want the behaviour.
      def put(tube_name, payload, ttr: DEFAULT_TTR, pri: DEFAULT_PRI, delay: 0, con: nil, idp: nil)
        opts = {ttr: ttr, pri: pri, delay: delay}
        opts[:con] = con unless con.nil?
        opts[:idp] = idp unless idp.nil?
        with_producer do |conn|
          conn.tubes[tube_name].put(JSON.generate(payload), **opts)
        end
      end

      # Consumers WATCH tubes; producers USE them. Keeping consumers on their
      # own connection avoids leaking watched-tube state into web threads.
      def consumer_client
        ::Tuber.new(address)
      end

      # Distinguishes "tuber is up with an empty queue" from "tuber is
      # unreachable" — queue_depth reports both as 0, which makes a down queue
      # look healthy. A stats call that answers means up; a tube tuber hasn't
      # created yet still counts as up.
      def reachable?
        with_producer { |conn| conn.tubes[INBOUND_TUBE].stats }
        true
      rescue ::Tuber::NotFoundError
        true
      rescue
        false
      end

      # Total pending jobs, for the header chrome and the health endpoint.
      def queue_depth
        with_producer do |conn|
          ALL_TUBES.sum do |name|
            conn.tubes[name].stats.current_jobs_ready.to_i
          rescue ::Tuber::NotFoundError
            0
          end
        end
      rescue
        0
      end

      # Per-tube backlog. Fetched live — tuber's stats are in memory, so there's
      # nothing to gain from caching a snapshot. An unreachable tuber yields {}
      # rather than raising into the request path.
      def queue_depths
        with_producer do |conn|
          ALL_TUBES.to_h do |name|
            s = conn.tubes[name].stats
            [name, {ready: s.current_jobs_ready.to_i, reserved: s.current_jobs_reserved.to_i,
                    buried: s.current_jobs_buried.to_i, delayed: s.current_jobs_delayed.to_i}]
          rescue ::Tuber::NotFoundError
            [name, {ready: 0, reserved: 0, buried: 0, delayed: 0}]
          end
        end
      rescue => e
        Rails.logger.warn("Ingest::Tuber.queue_depths failed: #{e.class}: #{e.message}")
        {}
      end
    end
  end
end
