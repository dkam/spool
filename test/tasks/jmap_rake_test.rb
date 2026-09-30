# frozen_string_literal: true

require "test_helper"
require "rake"

# `bin/rails jmap:rewind` — the way back for mail a consumer gave up on. The
# message is still in the mailbox; moving the cursor to when it arrived makes
# the next poll read it again, and everything after it too, which message_id
# dedup absorbs.
class JmapRakeTest < ActiveSupport::TestCase
  KEY = "jmap:Spool"

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("jmap:rewind")
    IngestCursor.advance(KEY, Jmap::Poller::Cursor.new("2026-09-30T05:00:00Z", ["M9"]).dump)
  end

  test "rewinds to the earliest failed message by default" do
    DroppedMail.create!(kind: "failed", reason: "boom", message_id: "<a@x>", received_at: Time.utc(2026, 9, 30, 3, 8, 44))
    DroppedMail.create!(kind: "failed", reason: "boom", message_id: "<b@x>", received_at: Time.utc(2026, 9, 30, 4, 0, 0))
    # A rejection isn't missing: it was turned away on purpose and would be again.
    DroppedMail.create!(kind: "rejected", reason: "precedence: bulk", message_id: "<c@x>", received_at: Time.utc(2026, 9, 1))

    assert_output(/2026-09-30T03:08:44Z/) { rewind }

    cursor = Jmap::Poller::Cursor.parse(IngestCursor.position_for(KEY))
    assert_equal "2026-09-30T03:08:44Z", cursor.at
    assert_empty cursor.ids
  end

  test "takes an explicit time" do
    assert_output(/2026-09-29T00:00:00Z/) { rewind("2026-09-29T00:00:00Z") }

    assert_equal "2026-09-29T00:00:00Z", Jmap::Poller::Cursor.parse(IngestCursor.position_for(KEY)).at
  end

  # Forward would step over mail that has never been read, silently and for
  # good. That is the one move this must never make.
  test "refuses to move the cursor forward" do
    assert_raises(SystemExit) do
      assert_output(nil, /only moves it back/) { rewind("2026-10-01T00:00:00Z") }
    end

    assert_equal "2026-09-30T05:00:00Z", Jmap::Poller::Cursor.parse(IngestCursor.position_for(KEY)).at
  end

  test "with nothing failed and no time given, says what to do instead" do
    assert_raises(SystemExit) do
      assert_output(nil, /jmap:rewind\[/) { rewind }
    end
  end

  private

  def rewind(time = nil)
    with_env("SPOOL_JMAP_FOLDER" => nil) do
      Rake::Task["jmap:rewind"].reenable
      Rake::Task["jmap:rewind"].invoke(*[time].compact)
    end
  end
end
