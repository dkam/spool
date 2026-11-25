# frozen_string_literal: true

module SpoolMcp
  class GiveUpReply < MCP::Tool
    tool_name "give_up_reply"
    description "Stop trying to deliver a reply that hasn't gone out. It is never sent, leaves mail_status's " \
      "undelivered list and the header's count, and get_ticket shows it as given up, signed by you. " \
      "The ticket's state is left alone. A reply the customer's mail server refused or bounced is already " \
      "marked this way; this is for one stuck for any other reason. message_id is a message's id from get_ticket."
    annotations(destructive_hint: false, idempotent_hint: false, open_world_hint: false)
    input_schema(
      properties: {
        message_id: {type: "integer"},
        agent_email: {
          type: "string",
          description: "Who gives up. Over a token connection it is always the token's agent, and this may only name them. " \
            "Over the local stdio server it names an existing agent; omit it to write as the MCP stand-in."
        }
      },
      required: ["message_id"]
    )

    class << self
      def call(message_id:, agent_email: nil, server_context: nil)
        message = Message.find(message_id)
        agent = SpoolMcp.author(agent_email, server_context)

        # This process runs outside the DatabaseSelector middleware, so it
        # wraps its writes the way jobs do — see ApplicationRecord.writing.
        ApplicationRecord.writing { message.give_up_delivery!(agent: agent) }

        SpoolMcp.ok(
          message_id: message.id,
          ticket_id: message.ticket_id,
          delivery_failed_at: message.delivery_failed_at.utc.iso8601,
          delivery_error: message.delivery_error
        )
      rescue ActiveRecord::RecordNotFound
        SpoolMcp.error("No message with id #{message_id}.")
      rescue Message::NotAwaitingDelivery
        SpoolMcp.error("Message #{message_id} isn't a reply waiting to be delivered — " \
          "it's a note, an inbound message, already delivered, or already given up on.")
      rescue ToolError, ActiveRecord::RecordInvalid => e
        SpoolMcp.error(e.message)
      end
    end
  end
end
