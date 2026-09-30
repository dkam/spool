# frozen_string_literal: true

module SpoolMcp
  class MailStatus < MCP::Tool
    tool_name "mail_status"
    description "Whether mail is moving, and if not, why. Same problems the header shows, with the detail " \
      "to chase them: when the mailbox was last polled cleanly and how far it has read, the last message " \
      "ingested, live queue depths, mail that reached Spool but was turned away or given up on, and " \
      "replies not yet delivered. Start here for \"why isn't this email in Spool?\"."
    annotations(read_only_hint: true, destructive_hint: false, open_world_hint: false)
    input_schema(properties: {})

    RECENT = 20

    class << self
      def call(server_context: nil)
        health = MailHealth.new

        SpoolMcp.ok(
          ok: health.ok?,
          problems: health.problems.map(&:to_h),
          polling: polling(health),
          last_ingested: last_ingested,
          queues: queues,
          # Mail that arrived and was given up on. Still in the mailbox:
          # `bin/rails jmap:rewind` (to the earliest received_at) reads it again.
          failed: health.failed.latest_first.map { |d| dropped(d) },
          # Turned away on purpose — auto-replies, bounces, bulk and list mail.
          rejected: DroppedMail.rejected.latest_first.limit(RECENT).map { |d| dropped(d) },
          # Every undelivered reply, however old; the header only counts the last week's.
          undelivered: health.undelivered(within: 100.years).map { |m| undelivered(m) }
        )
      end

      private

      def polling(health)
        key = Jmap::Poller.cursor_key
        cursor = Jmap::Poller::Cursor.parse(IngestCursor.position_for(key))

        {
          configured: Jmap::Poller.configured?,
          source: key,
          last_clean_poll_at: iso(health.polled_at),
          # The receivedAt of the newest message read — where the next poll starts.
          read_up_to: cursor&.at
        }
      end

      def last_ingested
        message = Message.inbound.order(:created_at).last
        return unless message

        {at: iso(message.created_at), ticket_id: message.ticket_id, from: message.from_email, subject: message.subject}
      end

      # Live, unlike the header: this is asked for, not rendered on every page.
      def queues
        return "unreachable" unless Ingest::Tuber.reachable?

        Ingest::Tuber.queue_depths
      end

      def dropped(record)
        {
          reason: record.reason,
          from: record.from_email,
          subject: record.subject,
          message_id: record.message_id,
          received_at: iso(record.received_at),
          dropped_at: iso(record.updated_at)
        }.compact
      end

      def undelivered(message)
        {message_id: message.id, ticket_id: message.ticket_id, composed_at: iso(message.sent_at)}
      end

      def iso(time) = time&.utc&.iso8601
    end
  end
end
