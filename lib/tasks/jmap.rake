# frozen_string_literal: true

namespace :jmap do
  desc "Move the JMAP poller back to re-read mail from TIME (default: the earliest failed message)"
  task :rewind, [:time] => :environment do |_, args|
    # The way back for mail that Ingest::InboundConsumer gave up on. Spool never
    # writes to the mailbox, so the message is still there; moving the cursor
    # to when it arrived makes the next poll read it again. Everything after it
    # is read again too, and the unique index on messages.message_id makes that
    # a no-op. Rejected mail is rejected again, which is why the default only
    # looks at failures.
    #
    #   bin/rails jmap:rewind                              # earliest failure
    #   bin/rails "jmap:rewind[2026-09-29T00:00:00Z]"      # an explicit time
    #
    # Times are the mailbox's receivedAt, UTC unless the string says otherwise.
    # The MCP mail_status tool lists each failure's.
    key = Jmap::Poller.cursor_key

    to =
      if args[:time].present?
        begin
          Time.zone.parse(args[:time])
        rescue ArgumentError
          nil
        end || abort("Can't read #{args[:time].inspect} as a time.")
      else
        DroppedMail.failed.minimum(:received_at) ||
          abort("No failed mail to rewind to. Give a time instead: bin/rails \"jmap:rewind[2026-09-29T00:00:00Z]\"")
      end
    to = to.utc.iso8601

    # Only backwards. Forwards would step the cursor over mail that has never
    # been read, silently and for good.
    current = Jmap::Poller::Cursor.parse(IngestCursor.position_for(key))
    if current && current.at < to
      abort "#{key} is at #{current.at}, before #{to}. Rewinding only moves it back — forward would skip mail."
    end

    IngestCursor.advance(key, Jmap::Poller::Cursor.new(to, []).dump)
    puts "Rewound #{key} to #{to}. The next poll re-reads from there; anything already in Spool is skipped."
  end
end
