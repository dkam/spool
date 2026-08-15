# frozen_string_literal: true

module SpoolMcp
  class ListTickets < MCP::Tool
    tool_name "list_tickets"
    description "List tickets, newest activity first. Defaults to open — the inbox. " \
      "Each row carries a preview of its latest message (or, when searching, of the message that matched)."
    annotations(read_only_hint: true, destructive_hint: false, open_world_hint: false)
    input_schema(
      properties: {
        state: {
          type: "string",
          enum: [*STATES.keys, TicketsController::ALL_STATES],
          description: "open = customer is waiting on us (default), waiting = we are waiting on the customer."
        },
        assignee: {
          type: "string",
          description: "An agent's email, or \"unassigned\". Omit for tickets assigned to anyone."
        },
        q: {
          type: "string",
          description: "Full-text search over message subjects and bodies."
        },
        tag: {
          type: "string",
          description: "Only tickets carrying this tag. Omitted, spam-tagged tickets are hidden — pass tag: \"spam\" to see them."
        },
        limit: {type: "integer"}
      },
      required: []
    )

    class << self
      def call(state: "open", assignee: nil, q: nil, tag: nil, limit: 50, server_context: nil)
        scope = Ticket.includes(:customer, :assignee, :tags)
          .recent_first
          .limit(limit.clamp(1, TicketsController::LIST_LIMIT))
        scope = scope.where(state: STATES.fetch(state)) unless state == TicketsController::ALL_STATES

        # Same deal as the UI: no tag filter means the inbox, and the inbox
        # hides spam.
        scope = tag.present? ? scope.tagged(tag) : scope.not_tagged(Tag::SPAM)

        # {ticket_id => matched message_id}, so the preview can show the hit
        # rather than whatever happens to be newest — same trade the UI makes.
        matches = Search::Fts.ticket_matches(q, limit: TicketsController::LIST_LIMIT) if q.present?
        scope = scope.where(id: matches.keys) if matches

        scope = case assignee
        when nil then scope
        when "unassigned" then scope.unassigned
        else scope.assigned_to(SpoolMcp.named_agent(assignee))
        end

        tickets = scope.to_a
        previews = previews_for(tickets, matches)

        SpoolMcp.ok(
          count: tickets.size,
          tickets: tickets.map { |t| SpoolMcp.ticket_summary(t, preview: previews[t.id]&.body_excerpt) }
        )
      rescue ToolError => e
        SpoolMcp.error(e.message)
      rescue KeyError
        SpoolMcp.error("Unknown state #{state.inspect}. Use open, waiting, closed or all.")
      end

      private

      # One query for the whole page, ascending so the newest message wins each
      # key — the same shape as the controller's latest_messages_for, and a
      # narrow select for the same reason: Message#body decompresses a blob.
      def previews_for(tickets, matches)
        return {} if tickets.empty?

        scope = Message.where(ticket_id: tickets.map(&:id))
          .select(:id, :ticket_id, :body_excerpt, :sent_at)

        return scope.where(id: matches.values).index_by(&:ticket_id) if matches

        scope.order(:sent_at, :id).index_by(&:ticket_id)
      end
    end
  end
end
