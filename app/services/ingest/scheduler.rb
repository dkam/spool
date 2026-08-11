# frozen_string_literal: true

require "rufus-scheduler"

module Ingest
  # Reads config/schedule.yml and pushes each entry onto its named tube on the
  # given schedule. This is what Solid Queue's recurring.yml would have done;
  # doing it here keeps recurring work on tuber with everything else.
  #
  # One process, and if it dies no recurring jobs fire until it restarts. That's
  # the trade for not putting a scheduler table in SQLite. Nothing Spool
  # schedules is safety-critical — the worst case for a missed IMAP poll is that
  # mail arrives a minute late.
  class Scheduler
    SCHEDULE_PATH = Rails.root.join("config", "schedule.yml")

    def initialize
      @rufus = Rufus::Scheduler.new
      @stop = false
    end

    def stop!
      @stop = true
      @rufus.shutdown(:kill)
    end

    def run
      register_jobs
      Rails.logger.info "[Scheduler] running with #{@rufus.jobs.size} job(s)"
      sleep 1 until @stop
    end

    private

    def register_jobs
      schedule.each do |name, entry|
        register(
          name,
          entry.fetch("class"),
          entry.fetch("tube"),
          entry.fetch("schedule"),
          entry["con"],
          entry["idp"],
          entry["args"] || []
        )
      end
    end

    # `idp:` makes the put idempotent — tuber suppresses it if a job with the
    # same key is already in the tube, ready or reserved. For a poll that
    # occasionally runs longer than its own interval (a slow IMAP round trip),
    # this is what stops the scheduler stacking duplicates behind it.
    #
    # `con:` caps how many jobs sharing that key tuber will hand out at once,
    # across every consumer.
    def register(name, klass, tube, sched, con, idp, args)
      method, expr = sched.split(/\s+/, 2)
      payload = {class: klass, args: args}

      put_opts = {}
      put_opts[:con] = con unless con.nil?
      put_opts[:idp] = idp unless idp.nil?

      # lambda do ... end, not -> { ... }: a brace-delimited lambda can't carry a
      # bare rescue, and this one needs it.
      handler = lambda do
        Rails.logger.info "[Scheduler] firing #{name} → #{tube}"
        Tuber.put(tube, payload, **put_opts)
      rescue => e
        # A scheduler that dies on one failed put stops firing everything else.
        Rails.logger.error "[Scheduler] #{name} failed to enqueue: #{e.class}: #{e.message}"
      end

      case method
      when "every" then @rufus.every(expr, &handler)
      when "cron" then @rufus.cron(expr, &handler)
      else raise "unknown schedule method '#{method}' for #{name}"
      end
    end

    def schedule
      @schedule ||= YAML.load_file(SCHEDULE_PATH) || {}
    end
  end
end
