# frozen_string_literal: true

require "test_helper"
require_relative "../../support/sentry_configured"

# The poll job's heartbeat to Splat's cron monitors.
#
# An error report says something went wrong; it cannot say that something
# stopped happening. The poll stopped for six weeks with nothing to report —
# the job was buried, so it never ran and never failed. A check-in on every
# successful poll gives Splat something to miss, and missing it is what raises
# the alarm, whatever the cause.
class Jmap::PollJobTest < ActiveSupport::TestCase
  include SentryConfigured

  test "a successful poll checks in" do
    with_sentry_configured do
      with_env("SPOOL_JMAP_TOKEN" => "t") do
        with_poller(-> { Jmap::Poller::Result.new(0, 0) }) { Jmap::PollJob.new.perform }
      end

      check_in = check_ins.sole
      assert_equal "jmap-poll", check_in.monitor_slug
      assert_equal :ok, check_in.status
      assert_equal({type: :interval, value: 1, unit: :minute},
        check_in.monitor_config.schedule.to_h)
    end
  end

  # The exception is reported by DispatchConsumer already. An error check-in on
  # top would have Splat raise an issue for every minute Fastmail is unreachable;
  # the missed check-in is what says the failure has lasted.
  test "a failed poll raises and does not check in" do
    with_sentry_configured do
      with_env("SPOOL_JMAP_TOKEN" => "t") do
        failing = -> { raise Jmap::Http::Error, "JMAP request failed: 503" }

        assert_raises(Jmap::Http::Error) do
          with_poller(failing) { Jmap::PollJob.new.perform }
        end
      end

      assert_empty check_ins
    end
  end

  # Checking in without polling would tell Splat mail is flowing when nothing is
  # reading the mailbox at all.
  test "no token, no check-in" do
    with_sentry_configured do
      with_env("SPOOL_JMAP_TOKEN" => nil) { Jmap::PollJob.new.perform }

      assert_empty check_ins
    end
  end

  private

  def check_ins
    sentry_events.grep(Sentry::CheckInEvent)
  end

  # Swaps Poller.from_env for one whose poll runs `poll`. The poller has its own
  # tests; this is only about what the job does with the outcome.
  def with_poller(poll)
    poller = Object.new
    poller.define_singleton_method(:poll) { poll.call }

    singleton = Jmap::Poller.singleton_class
    original = singleton.instance_method(:from_env)
    singleton.define_method(:from_env) { poller }
    yield
  ensure
    singleton.define_method(:from_env, original)
  end
end
