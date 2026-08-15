# frozen_string_literal: true

module SpoolMcp
  class UpdateTicket < MCP::Tool
    tool_name "update_ticket"
    description "Change a ticket's state (open / waiting / closed), its assignee, or its tags. " \
      "Replying already moves a ticket to waiting — this is for the manual moves, like closing. " \
      "Tagging \"spam\" also blocks the sender (their future mail arrives tagged spam); " \
      "removing it unblocks them."
    annotations(destructive_hint: false, idempotent_hint: true, open_world_hint: false)
    input_schema(
      properties: {
        id: {type: "integer"},
        state: {type: "string", enum: STATES.keys},
        assignee: {
          type: "string",
          description: "An agent's email, or \"unassigned\" to clear the assignment."
        },
        add_tags: {
          type: "array",
          items: {type: "string"},
          description: "Tag names to add. Created on first use; lowercased."
        },
        remove_tags: {
          type: "array",
          items: {type: "string"},
          description: "Tag names to remove. Unknown names are ignored."
        }
      },
      required: ["id"]
    )

    class << self
      def call(id:, state: nil, assignee: nil, add_tags: nil, remove_tags: nil, server_context: nil)
        ticket = Ticket.find(id)

        updates = {}
        updates[:state] = STATES.fetch(state) if state
        unless assignee.nil?
          updates[:assignee] = (SpoolMcp.named_agent(assignee) unless assignee == "unassigned")
        end
        if updates.empty? && Array(add_tags).empty? && Array(remove_tags).empty?
          return SpoolMcp.error("Nothing to change: pass state, assignee and/or tags.")
        end

        # This process runs outside the DatabaseSelector middleware, so it
        # wraps its writes the way jobs do — see ApplicationRecord.writing.
        ApplicationRecord.writing do
          ticket.update!(updates) if updates.any?
          Array(add_tags).each { |name| apply_tag(ticket, name) }
          Array(remove_tags).each { |name| remove_tag(ticket, name) }
        end

        SpoolMcp.ok(SpoolMcp.ticket_summary(ticket.reload))
      rescue ActiveRecord::RecordNotFound
        SpoolMcp.error("No ticket with id #{id}.")
      rescue KeyError
        SpoolMcp.error("Unknown state #{state.inspect}. Use open, waiting or closed.")
      rescue ToolError, ActiveRecord::RecordInvalid => e
        SpoolMcp.error(e.message)
      end

      private

      # "spam" is the tag with behaviour: it travels with blocking the sender,
      # and the model owns that pairing so no caller can apply half of it.
      def apply_tag(ticket, name)
        spam?(name) ? ticket.mark_spam! : ticket.tag!(name)
      end

      def remove_tag(ticket, name)
        spam?(name) ? ticket.unmark_spam! : ticket.untag!(name)
      end

      def spam?(name)
        Tag.normalize_value_for(:name, name) == Tag::SPAM
      end
    end
  end
end
