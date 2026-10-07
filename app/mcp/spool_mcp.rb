# frozen_string_literal: true

# Spool's MCP server: the domain exposed as typed tools, so an agent (Claude
# Code, or anything else speaking MCP) can read and work tickets without
# scraping the UI. Served two ways: over HTTP at POST /mcp with an agent's
# bearer token (McpController), and over stdio by bin/mcp, registered for this
# repo in .mcp.json. See docs/mcp.md.
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

  # `agent` is who this connection is: the token's owner over HTTP, nil over
  # stdio. It rides in the server context to every tool call, and #author
  # signs writes with it. Built per request over HTTP, since the agent differs.
  def server(agent: nil)
    MCP::Server.new(
      name: "spool",
      version: Spool::VERSION,
      tools: [ListTickets, GetTicket, AddNote, ReplyToTicket, UpdateTicket, MailStatus],
      server_context: {agent: agent},
      configuration: MCP::Configuration.new(exception_reporter: method(:report_exception)),
      instructions: <<~TEXT
        Spool is a small email helpdesk. Tickets belong to customers and hold a
        chronological thread of messages: "inbound" from the customer,
        "outbound" replies from an agent, and "note" for internal notes the
        customer never sees. Ticket states are open (customer is waiting on
        us), waiting (we are waiting on the customer) and closed.

        Start with list_tickets (defaults to open — the inbox), read a thread
        with get_ticket, and write with add_note, reply_to_ticket or
        update_ticket. Writes are signed by the agent whose token this
        connection uses. reply_to_ticket emails a real customer (asynchronously,
        via the configured outbound transport) wherever delivery is configured — its response says
        whether the reply was queued or only stored.

        Tickets can carry tags (update_ticket's add_tags / remove_tags).
        The "spam" tag is special: adding it also blocks the sender, so
        their future mail is tagged spam on arrival, and removing it
        unblocks them. Spam-tagged tickets are hidden from every list
        unless you ask with list_tickets' tag parameter.

        When mail seems to be missing — "why isn't this email in Spool?" —
        call mail_status. It says whether the mailbox is being polled, how far
        it has read, and lists mail that arrived but was turned away (bulk,
        auto-replies, lists) or given up on, plus replies not yet delivered.
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

  # The author for a write.
  #
  # A connection with an agent (HTTP, by token) writes as that agent and only
  # that agent: agent_email may name them, but naming a colleague is refused
  # rather than ignored, so a caller who meant to sign as someone else finds
  # out. Without one (stdio, run by whoever has a shell on the box) agent_email
  # picks the author, and omitting it writes as the stand-in.
  #
  # A named agent must already exist — this server provisions nobody but its
  # own stand-in, so a typo'd email is an error, not a new colleague.
  def author(agent_email, server_context = nil)
    if (connected = connected_agent(server_context))
      return connected if agent_email.blank? || Agent.normalize_value_for(:email, agent_email) == connected.email

      raise ToolError, "This connection writes as #{connected.email}; agent_email can't name anyone else."
    end

    return mcp_agent if agent_email.blank?

    named_agent(agent_email)
  end

  # `try`, because the context is an MCP::ServerContext wrapping the hash given
  # to #server (it forwards #[]), a plain hash in tests, or wraps nil on stdio.
  def connected_agent(server_context)
    server_context.try(:[], :agent)
  end

  # The gem turns an exception escaping a tool into an opaque "Internal error
  # calling tool …" for the client — deliberately, so internals don't leak —
  # and hands the exception here. Without a reporter it goes nowhere at all.
  #
  # It hands over the caller's mistakes too (an unknown tool, bad params, an
  # unsupported protocol version), as RequestHandlerErrors with no original
  # error behind them. Those are answered to the client already, and are
  # nothing to fix here.
  def report_exception(exception, _context = nil)
    return if exception.is_a?(MCP::Server::RequestHandlerError) && exception.error_type != :internal_error

    Rails.logger.error("MCP tool error: #{exception.class}: #{exception.message}")
    Sentry.capture_exception(exception)
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
