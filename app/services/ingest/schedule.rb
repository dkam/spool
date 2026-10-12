# frozen_string_literal: true

module Ingest
  # Spool's recurring jobs. config/schedule.yml is the whole set, and tuber runs
  # it: each entry is synced to the server under the owner "spool", and tuber
  # puts the entry's `{class:, args:}` body onto its tube when it falls due.
  # Ingest::DispatchConsumer drains the tube as before.
  #
  # Every worker syncs once at boot (bin/worker). A sync replaces the owner's
  # whole set, so an entry deleted from the file is deleted from tuber, and an
  # identical sync changes nothing — two workers booting together is harmless.
  # Syncing only at boot, never on reconnect, is the gem's advice: during a
  # rolling deploy an old worker re-syncing would put back what the new release
  # removed.
  #
  # Tuber keeps the schedule across its own restarts (it's in the binlog), and
  # keeps running the last good one if a sync is refused.
  module Schedule
    OWNER = "spool"
    PATH = Rails.root.join("config", "schedule.yml")

    KEYS = %w[class tube args every offset cron zone idp con catchup].freeze

    # Same cadence the consumers use to wait for tuber.
    SYNC_RETRY_INTERVAL = TubeConsumer::CONNECT_RETRY_INTERVAL

    class << self
      def entries(path = PATH)
        YAML.load_file(path) || {}
      end

      # Stages each entry on a ::Tuber::Schedules::Builder. Raises
      # ArgumentError, before anything is sent, on an entry tuber would refuse
      # or a key this doesn't know.
      def build(builder, entries = self.entries)
        entries.each do |name, entry|
          unknown = entry.keys - KEYS
          if unknown.any?
            raise ArgumentError, "config/schedule.yml: #{name} has unknown key(s) #{unknown.join(", ")} " \
                                 "(expected #{KEYS.join(", ")})"
          end

          builder.add(
            name,
            tube: entry.fetch("tube"),
            body: JSON.generate({class: entry.fetch("class"), args: entry["args"] || []}),
            every: entry["every"], offset: entry["offset"],
            cron: entry["cron"], zone: entry["zone"],
            idp: entry["idp"], con: entry["con"],
            catchup: catchup(entry["catchup"]),
            pri: Tuber::DEFAULT_PRI, ttr: Tuber::DEFAULT_TTR
          )
        end
      end

      def sync!
        Tuber.with_producer do |client|
          client.schedules.sync(OWNER) { |s| build(s) }
        end
      end

      # Syncs, waiting for tuber as long as it takes to answer — a worker boots
      # alongside it. A schedule tuber refuses (or that won't build) is logged
      # and reported, and not retried: it would be refused again, and tuber is
      # still running the previous one.
      def sync_at_boot(retry_interval: SYNC_RETRY_INTERVAL)
        attempt = 0
        begin
          result = sync!
          Rails.logger.info "[Schedule] synced #{OWNER}: #{result.to_h}"
          result
        rescue *Tuber::CONNECTION_ERRORS => e
          attempt += 1
          Rails.logger.warn "[Schedule] waiting for tuber (attempt #{attempt}): #{e.class}: #{e.message}"
          sleep retry_interval
          retry
        rescue => e
          Rails.logger.error "[Schedule] sync failed: #{e.class}: #{e.message}"
          Sentry.capture_exception(e, tags: {service: "schedule"})
          nil
        end
      end

      private

      # "once", "never", or a number of seconds. Absent means :once, the gem's
      # default: a tick missed while tuber was down fires once for the gap.
      def catchup(value)
        case value
        when nil then :once
        when String then value.to_sym
        else value
        end
      end
    end
  end
end
