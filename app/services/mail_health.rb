# frozen_string_literal: true

# Is mail moving? The header asks on every page, and says something only when
# the answer is no.
#
# Everything here is read from the database, never from tuber: the header
# renders on every page, and a queue that is down or hung must not slow down
# the page that is trying to say so. Nothing is lost by it, because since no
# consumer buries anything, each way mail stops leaves its mark in SQLite:
#
#   polling      the poller hasn't completed a clean poll lately — Fastmail is
#                down, the token was revoked, the scheduler or the worker or
#                tuber itself is down, or one message can't be fetched and is
#                holding the cursor.
#   failed       a message reached Spool and was given up on (DroppedMail).
#   undelivered  a reply was composed and hasn't gone out.
#
# The MCP mail_status tool reports the same problems alongside the detail an
# agent needs to chase them, live queue stats included.
class MailHealth
  include ActionView::Helpers::DateHelper
  include ActionView::Helpers::TextHelper

  # The same point Jmap::PollJob's Splat monitor alarms at: a one-minute
  # schedule plus five minutes' margin. A deploy or a Fastmail blip passes
  # quietly inside it.
  POLL_STALE_AFTER = 6.minutes

  # A send's retries take under a minute. Past this a reply isn't slow, it
  # isn't going.
  UNDELIVERED_AFTER = 15.minutes

  # And past this it is old news — dealt with, or deliberately left — rather
  # than something that just broke. mail_status still lists it.
  UNDELIVERED_WITHIN = 7.days

  # `hint` is the next step, for the header's tooltip.
  Problem = Data.define(:key, :summary, :hint)

  def initialize(now: Time.current)
    @now = now
  end

  def problems
    [polling_problem, failed_problem, undelivered_problem].compact
  end

  def ok? = problems.empty?

  def polled_at
    return @polled_at if defined?(@polled_at)

    @polled_at = IngestCursor.find_by(source: Jmap::Poller.cursor_key)&.polled_at
  end

  def failed = DroppedMail.failed

  # Replies that should have gone by now and haven't, oldest first.
  def undelivered(within: UNDELIVERED_WITHIN)
    Message.outbound.where(delivered_at: nil)
      .where(sent_at: (@now - within)..(@now - UNDELIVERED_AFTER))
      .order(:sent_at)
  end

  private

  # No token, no poller, nothing to be late — the same switch PollJob uses.
  def polling_problem
    return unless Jmap::Poller.configured?
    return if polled_at && polled_at > @now - POLL_STALE_AFTER

    Problem.new(:polling,
      polled_at ? "No mail check for #{distance_of_time_in_words(polled_at, @now)}" : "Mail has never been checked",
      "Nothing has polled the mailbox cleanly since. Check Splat's jmap-poll monitor and the worker log.")
  end

  def failed_problem
    count = failed.count
    return if count.zero?

    Problem.new(:failed, "#{pluralize(count, "message")} failed to arrive",
      "Still in the mailbox. Once the cause is fixed, bin/rails jmap:rewind reads it again.")
  end

  # Unconfigured, a stored reply is the documented behaviour rather than a
  # fault: nothing was ever going to send it.
  def undelivered_problem
    return unless Outbound::Delivery.configured?

    count = undelivered.count
    return if count.zero?

    Problem.new(:undelivered, "#{pluralize(count, "reply", plural: "replies")} not delivered",
      "Once the cause is fixed, bin/rails outbound:backfill sends them.")
  end
end
