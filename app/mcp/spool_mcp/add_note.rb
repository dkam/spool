# frozen_string_literal: true

module SpoolMcp
  class AddNote < MCP::Tool
    tool_name "add_note"
    description "Add an internal note to a ticket's thread. Notes are never emailed and " \
      "do not change the ticket's state."
    annotations(destructive_hint: false, open_world_hint: false)
    input_schema(
      properties: {
        ticket_id: {type: "integer"},
        text: {type: "string"},
        agent_email: {
          type: "string",
          description: "Attribute the note to an existing agent. Omit to write as the MCP stand-in."
        }
      },
      required: ["ticket_id", "text"]
    )

    class << self
      def call(ticket_id:, text:, agent_email: nil, server_context: nil)
        ticket = Ticket.find(ticket_id)
        agent = SpoolMcp.author(agent_email)

        # This process runs outside the DatabaseSelector middleware, so it
        # wraps its writes the way jobs do — see ApplicationRecord.writing.
        message = ApplicationRecord.writing do
          Message.compose!(ticket: ticket, agent: agent, text: text, direction: "note")
        end

        SpoolMcp.ok(message_id: message.id, ticket_id: ticket.id, direction: "note", agent: agent.email)
      rescue ActiveRecord::RecordNotFound
        SpoolMcp.error("No ticket with id #{ticket_id}.")
      rescue ToolError, ActiveRecord::RecordInvalid => e
        SpoolMcp.error(e.message)
      end
    end
  end
end
