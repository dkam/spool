# frozen_string_literal: true

module SpoolMcp
  class GetTicket < MCP::Tool
    tool_name "get_ticket"
    description "A ticket with its full message thread, oldest first. " \
      "Messages with direction \"note\" are internal — the customer has never seen them."
    annotations(read_only_hint: true, destructive_hint: false, open_world_hint: false)
    input_schema(
      properties: {id: {type: "integer"}},
      required: ["id"]
    )

    class << self
      def call(id:, server_context: nil)
        ticket = Ticket.includes(:customer, :assignee, :tags).find(id)
        messages = ticket.messages.includes(:agent).chronological.to_a

        SpoolMcp.ok(
          SpoolMcp.ticket_summary(ticket).merge(messages: messages.map { |m| serialize(m) })
        )
      rescue ActiveRecord::RecordNotFound
        SpoolMcp.error("No ticket with id #{id}.")
      end

      private

      def serialize(message)
        {
          id: message.id,
          direction: message.direction,
          from: from(message),
          subject: message.subject,
          sent_at: message.sent_at&.utc&.iso8601,
          # Only ever present on outbound messages; compact drops it elsewhere.
          delivered_at: message.delivered_at&.utc&.iso8601,
          # The plain-text rendering; an HTML-only message falls back to its
          # quote-stripped excerpt rather than handing raw HTML to an agent.
          body: message.body_text || message.body_excerpt
        }.compact
      end

      def from(message)
        if message.inbound?
          {name: message.from_name, email: message.from_email}.compact
        else
          {name: message.agent&.display_name, email: message.agent&.email}.compact
        end
      end
    end
  end
end
