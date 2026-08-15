# frozen_string_literal: true

# Spool's MCP server: the domain exposed as typed tools, so an agent (Claude
# Code, or anything else speaking MCP) can read and work tickets without
# scraping the UI. Served over stdio by bin/mcp, registered for this repo in
# .mcp.json. See docs/mcp.md.
#
# The tools speak the UI's vocabulary, not the schema's — a ticket state is
# "open / waiting / closed", exactly what the filter chips and the URL say,
# and the pending↔waiting translation happens here, in one place, on the way
# in and out.
module SpoolMcp
  # UI word → column value, borrowed from the controller so there is exactly
  # one copy of the mapping.
  STATES = TicketsController::STATE_FILTERS

  # Writes composed over MCP with no agent named are attributed to this
  # stand-in — same pattern as open mode's development agent, and for the same
  # reason: `message.agent` must mean something, and a note signed "MCP" is
  # honest about where it came from.
  AGENT_SUB = "mcp"

  # An expected failure the caller can act on (unknown agent, bad argument) —
  # reported as a tool error response rather than a protocol-level exception.
  class ToolError < StandardError; end

  module_function

  def server
    MCP::Server.new(
      name: "spool",
      version: Spool::VERSION,
      tools: [ListTickets, GetTicket, AddNote, ReplyToTicket, UpdateTicket],
      instructions: <<~TEXT
        Spool is a small email helpdesk. Tickets belong to customers and hold a
        chronological thread of messages: "inbound" from the customer,
        "outbound" replies from an agent, and "note" for internal notes the
        customer never sees. Ticket states are open (customer is waiting on
        us), waiting (we are waiting on the customer) and closed.

        Start with list_tickets (defaults to open — the inbox), read a thread
        with get_ticket, and write with add_note, reply_to_ticket or
        update_ticket. reply_to_ticket emails a real customer (asynchronously,
        via Mailgun) wherever delivery is configured — its response says
        whether the reply was queued or only stored.

        Tickets can carry tags (update_ticket's add_tags / remove_tags).
        The "spam" tag is special: adding it also blocks the sender, so
        their future mail is tagged spam on arrival, and removing it
        unblocks them. Spam-tagged tickets are hidden from every list
        unless you ask with list_tickets' tag parameter.
      TEXT
    )
  end

  def ok(payload)
    MCP::Tool::Response.new([{type: "text", text: JSON.pretty_generate(payload)}])
  end

  def error(message)
    MCP::Tool::Response.new([{type: "text", text: message}], error: true)
  end

  def ui_state(db_state)
    STATES.key(db_state) || db_state
  end

  # The author for a write. A named agent must already exist — this server
  # provisions nobody but its own stand-in, so a typo'd email is an error, not
  # a new colleague.
  def author(agent_email)
    return mcp_agent if agent_email.blank?

    named_agent(agent_email)
  end

  def named_agent(email)
    Agent.find_by(email: email.to_s.strip.downcase) ||
      raise(ToolError, "No agent with email #{email.inspect}.")
  end

  def mcp_agent
    Agent.find_by(oidc_sub: AGENT_SUB) ||
      Agent.find_or_provision!(oidc_sub: AGENT_SUB, email: "mcp@localhost", name: "MCP")
  end

  def ticket_summary(ticket, preview: nil)
    {
      id: ticket.id,
      subject: ticket.subject || "(no subject)",
      state: ui_state(ticket.state),
      customer: {name: ticket.customer.display_name, email: ticket.customer.email},
      assignee: ticket.assignee&.email,
      # presence: an empty tag list is noise on every row; compact drops it.
      tags: ticket.tags.map(&:name).sort.presence,
      last_activity_at: ticket.last_activity_at&.utc&.iso8601,
      preview: preview
    }.compact
  end
end
