# frozen_string_literal: true

require "sentry/test_helper"

# Sentry is not initialized in test (no SENTRY_DSN), so a test that asserts on
# what gets reported starts the SDK itself. Events go to DummyTransport; nothing
# leaves the process.
module SentryConfigured
  include Sentry::TestHelper

  # Runs the real config/initializers/sentry.rb with a DSN in the environment,
  # rather than a hand-rolled Sentry.init that would only ever assert on itself.
  def with_sentry_configured(&block)
    with_env("SENTRY_DSN" => "http://public@splat.test/spool") do
      load Rails.root.join("config/initializers/sentry.rb").to_s
      setup_sentry_test { |config| config.background_worker_threads = 0 }
      yield
    end
  ensure
    teardown_sentry_test
    Sentry.close
  end
end
