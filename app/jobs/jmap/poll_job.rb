# frozen_string_literal: true

module Jmap
  # Plain class, not an ActiveJob: dispatched by name from config/schedule.yml
  # through Ingest::DispatchConsumer, which needs no serialisation contract.
  # Same shape as CleanupExpiredOidcSessionsJob.
  class PollJob
    # Splat's cron monitor for this job. Every successful poll checks in, and
    # Splat raises an issue once none has arrived for a minute plus the margin.
    # An error report can't say that polling stopped — a buried poll neither
    # runs nor fails — but a missing heartbeat does, whatever the cause.
    #
    # Only ever :ok. A failure is already reported as an exception by
    # Ingest::DispatchConsumer, and Splat treats a single :error check-in as an
    # incident, so one would page on every minute Fastmail is unreachable. The
    # margin is what lets a blip pass quietly and a real outage through.
    MONITOR_SLUG = "jmap-poll"
    MONITOR_CONFIG = Sentry::Cron::MonitorConfig.from_interval(1, :minute, checkin_margin: 5)

    def perform
      # Absence of a token is the whole switch, the same way SENTRY_DSN is for
      # error reporting: a checkout with no mail credentials runs the scheduler
      # without reaching for a mailbox. Logged at debug rather than warn so an
      # unconfigured development machine isn't noisy about it every 60 seconds.
      unless Poller.configured?
        Rails.logger.debug "[Jmap::PollJob] SPOOL_JMAP_TOKEN unset, skipping"
        return
      end

      Poller.from_env.poll
      Sentry.capture_check_in(MONITOR_SLUG, :ok, monitor_config: MONITOR_CONFIG)
    rescue Http::Unauthorized => e
      # No retry will fix a revoked or under-scoped token, and a helpdesk that
      # has quietly stopped receiving mail is the worst failure this system has.
      # Say so at error level, every poll, until someone fixes it.
      Rails.logger.error "[Jmap::PollJob] token rejected — inbound mail has stopped: #{e.message}"
      raise
    end
  end
end
