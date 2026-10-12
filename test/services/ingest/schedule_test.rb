# frozen_string_literal: true

require "test_helper"

# config/schedule.yml is synced to tuber, which runs it: there is no scheduler
# process of Spool's own any more. What matters here is that the file turns into
# the entries we mean, and that the sync at worker boot waits out a tuber that
# isn't up yet but doesn't loop on a schedule tuber refuses.
class Ingest::ScheduleTest < ActiveSupport::TestCase
  def build(entries = Ingest::Schedule.entries)
    builder = ::Tuber::Schedules::Builder.new
    Ingest::Schedule.build(builder, entries)
    builder.entries.index_by(&:name)
  end

  test "every entry in config/schedule.yml is one tuber's client accepts" do
    entries = build

    assert_equal %w[cleanup_expired_oidc_sessions jmap_poll], entries.keys.sort
  end

  # idp: is what stops a slow poll stacking a second poller behind it.
  test "jmap_poll fires every minute onto spool.maintenance, idempotently" do
    entry = build.fetch("jmap_poll")

    assert_match(/\Ajmap_poll spool\.maintenance /, entry.line)
    assert_includes entry.line.split, "idp:jmap_poll"
    assert entry.line.end_with?("every 60s"), entry.line
    assert_equal({"class" => "Jmap::PollJob", "args" => []}, JSON.parse(entry.body))
  end

  # The same priority and TTR the rufus scheduler's puts used.
  test "fires carry Spool's default priority and TTR" do
    entry = build.fetch("jmap_poll")
    _name, _tube, pri, _delay, ttr = entry.line.split

    assert_equal Ingest::Tuber::DEFAULT_PRI, pri.to_i
    assert_equal Ingest::Tuber::DEFAULT_TTR, ttr.to_i
  end

  test "cron entries keep their expression" do
    entry = build.fetch("cleanup_expired_oidc_sessions")

    assert entry.line.end_with?("17 * * * *"), entry.line
  end

  test "catchup: is passed through" do
    entry = build({"x" => {"class" => "Foo", "tube" => "spool.maintenance", "every" => "1h", "catchup" => "never"}})
      .fetch("x")

    assert_includes entry.line.split, "catchup:0"
  end

  # The old format said `schedule: every 60s`. Left in the file, it would build
  # an entry with no spec at all; better that the sync refuse and say why.
  test "an unknown key is refused by name" do
    error = assert_raises(ArgumentError) do
      build({"x" => {"class" => "Foo", "tube" => "spool.maintenance", "schedule" => "every 60s"}})
    end

    assert_match(/schedule/, error.message)
    assert_match(/\bx\b/, error.message)
  end

  test "the sync at boot waits for tuber to come up" do
    calls = 0
    synced = ::Tuber::Schedules::SyncResult.new(0, 0, 0, 2)
    sync = lambda do
      calls += 1
      raise ::Tuber::NotConnected, "connection refused" if calls < 3
      synced
    end

    result = stubbing(Ingest::Schedule, :sync!, sync) do
      Ingest::Schedule.sync_at_boot(retry_interval: 0)
    end

    assert_equal synced, result
    assert_equal 3, calls
  end

  # A refused schedule is the same schedule on every attempt. Tuber keeps
  # running the previous one, so log it and report it, and stop.
  test "the sync at boot gives up on a schedule tuber refuses" do
    calls = 0
    refuse = lambda do
      calls += 1
      raise ::Tuber::ScheduleSyncError.new("BAD_SCHEDULE", "schedule-put", owner: "spool", entry: "x")
    end

    result = stubbing(Ingest::Schedule, :sync!, refuse) do
      Ingest::Schedule.sync_at_boot(retry_interval: 0)
    end

    assert_nil result
    assert_equal 1, calls
  end
end
