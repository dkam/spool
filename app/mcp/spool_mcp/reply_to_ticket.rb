# frozen_string_literal: true

module SpoolMcp
  class ReplyToTicket < MCP::Tool
    tool_name "reply_to_ticket"
    description "Send a reply to the customer on a ticket. The ticket moves to waiting. " \
      "Delivery is asynchronous via the configured outbound transport (SMTP or Mailgun): " \
      "the reply is stored and queued, and the response's delivery field says whether sending " \
      "is configured in this environment. This emails a real customer."
    annotations(open_world_hint: false)
    input_schema(
      properties: {
        ticket_id: {type: "integer"},
        text: {type: "string"},
        subject: {
          type: "string",
          description: "Override the subject. Defaults to the ticket's subject with its [#id] threading tag."
        },
        agent_email: {
          type: "string",
          description: "Attribute the reply to an existing agent. Omit to write as the MCP stand-in."
        }
      },
      required: ["ticket_id", "text"]
    )

    class << self
      def call(ticket_id:, text:, subject: nil, agent_email: nil, server_context: nil)
        ticket = Ticket.find(ticket_id)
        agent = SpoolMcp.author(agent_email)

        # This process runs outside the DatabaseSelector middleware, so it
        # wraps its writes the way jobs do — see ApplicationRecord.writing.
        message = ApplicationRecord.writing do
          Message.compose!(ticket: ticket, agent: agent, text: text, subject: subject)
        end

        SpoolMcp.ok(
          message_id: message.id,
          ticket_id: ticket.id,
          direction: "outbound",
          agent: agent.email,
          state: SpoolMcp.ui_state(ticket.reload.state),
          delivery: Outbound::Delivery.configured? ? "queued" : "not configured — the reply is stored, nothing is emailed"
        )
      rescue ActiveRecord::RecordNotFound
        SpoolMcp.error("No ticket with id #{ticket_id}.")
      rescue ToolError, ActiveRecord::RecordInvalid => e
        SpoolMcp.error(e.message)
      end
    end
  end
end
