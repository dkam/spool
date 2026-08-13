# frozen_string_literal: true

module Jmap
  # Plain class, not an ActiveJob: dispatched by name from config/schedule.yml
  # through Ingest::DispatchConsumer, which needs no serialisation contract.
  # Same shape as CleanupExpiredOidcSessionsJob.
  class PollJob
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
    rescue Http::Unauthorized => e
      # No retry will fix a revoked or under-scoped token, and a helpdesk that
      # has quietly stopped receiving mail is the worst failure this system has.
      # Say so at error level, every poll, until someone fixes it.
      Rails.logger.error "[Jmap::PollJob] token rejected — inbound mail has stopped: #{e.message}"
      raise
    end
  end
end
