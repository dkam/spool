# frozen_string_literal: true

require "test_helper"
require "sentry/test_helper"

# What actually gets reported, as opposed to what merely gets logged.
#
# The distinction is the whole point of wiring Sentry up. An exception that
# reaches the Rack middleware is reported without anyone doing anything; the
# ones worth testing are the ones the application deliberately swallows to keep
# serving — a consumer that must keep draining its tube, a login that must not
# 500. Those are silent by construction, and a silent failure nobody is told
# about is how a broken login survived in production long enough to be found by
# reading logs over someone's shoulder.
#
# Sentry is not initialized in test (no SENTRY_DSN), so each test starts the SDK
# itself. Events go to DummyTransport; nothing leaves the process.
class ErrorReportingTest < ActiveSupport::TestCase
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

  # --- the initializer -----------------------------------------------------

  test "no DSN means the SDK never starts" do
    with_env("SENTRY_DSN" => nil) do
      load Rails.root.join("config/initializers/sentry.rb").to_s

      refute Sentry.initialized?, "development and test must not report anywhere"
      assert_nothing_raised { Sentry.capture_exception(RuntimeError.new("ignored")) }
    end
  end

  test "the release names both the version and the commit" do
    with_sentry_configured do
      assert_equal "#{Spool::VERSION}+#{Rails.application.config.x.revision}",
        Sentry.configuration.release
    end
  end

  # A helpdesk's exception payloads would otherwise carry customer
  # correspondence: request bodies, cookies, IPs.
  test "PII is off" do
    with_sentry_configured do
      assert_equal false, Sentry.configuration.send_default_pii
    end
  end

  test "health checks are never sampled, whatever the rate says" do
    with_env("SENTRY_TRACES_SAMPLE_RATE" => "1.0") do
      with_sentry_configured do
        sampler = Sentry.configuration.traces_sampler

        assert_equal 0.0, sampler.call(sampling_context("/up"))
        assert_equal 1.0, sampler.call(sampling_context("/tickets"))
      end
    end
  end

  test "transactions are off by default" do
    with_sentry_configured do
      assert_equal 0.0, Sentry.configuration.traces_sampler.call(sampling_context("/tickets"))
    end
  end

  def sampling_context(name)
    {transaction_context: {name: name, op: "http.server"}, parent_sampled: nil}
  end

  # --- what the application swallows ---------------------------------------

  # Stands in for a consumer whose work blows up. Every consumer failure — the
  # run loop's own rescues and each subclass's per-job one — funnels through
  # log_exception, so this covers all of them.
  class ExplodingConsumer < Ingest::TubeConsumer
    def initialize = super(tube: "spool.test")

    def explode
      raise ArgumentError, "job body was nonsense"
    rescue => e
      log_exception("[ExplodingConsumer] job failed", e)
    end
  end

  test "a consumer failure is reported, not just logged" do
    with_sentry_configured do
      ExplodingConsumer.new.explode

      assert_equal 1, sentry_events.size
      exception = sentry_events.first.exception.values.first
      assert_equal "ArgumentError", exception.type
      # Not assert_equal: Ruby's error_highlight appends the offending source
      # line to the message.
      assert_includes exception.value, "job body was nonsense"
    end
  end

  # Workers have no request context, so without this an issue in Splat says only
  # that an ArgumentError happened somewhere in the process.
  test "a consumer failure names the consumer" do
    with_sentry_configured do
      ExplodingConsumer.new.explode

      assert_equal "ErrorReportingTest::ExplodingConsumer", sentry_events.first.tags[:consumer]
    end
  end
end
