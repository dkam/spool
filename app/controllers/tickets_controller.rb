class TicketsController < ApplicationController
  # The design's filter chips read "Open / Waiting / Closed"; the column stores
  # "open / pending / closed". Mapping them here keeps the query-string values
  # stable and readable in the URL, and keeps the label translation in one place
  # rather than smeared across the view.
  STATE_FILTERS = {"open" => "open", "waiting" => "pending", "closed" => "closed"}.freeze

  # A wide cap rather than pagination. The design has no pager, and Pagy is in
  # the Gemfile but unwired (see docs/ui-contract.md); this keeps one screen
  # honest without inventing UI the design doesn't have. Revisit with Pagy when
  # a real inbox outgrows it.
  LIST_LIMIT = 200

  def index
    @state_filter = params[:state].presence_in(STATE_FILTERS.keys)
    @assignee_filter = params[:assignee].presence
    @query = params[:q].to_s.strip.presence

    # Search is another narrowing of this list, not a screen of its own, so it
    # composes with the filters above rather than replacing them.
    if searching?
      @matches = Search::Fts.ticket_matches(@query, limit: LIST_LIMIT)
      # Capped independently of the tickets. Inheriting one cap would let the
      # two sections disagree on screen about how much exists.
      @customers = Customer.search(@query).to_a
      @customer_counts = ticket_counts_for(@customers)
    end

    @tickets = filtered_tickets
    @latest_messages = latest_messages_for(@tickets)

    @open_count = Ticket.open_state.count
    # Scoped to unresolved: a closed ticket nobody ever opened is not something
    # the header should nag about.
    @unread_count = Ticket.unresolved.unread_for(current_agent).count
    @agents = Agent.order(:name, :email).to_a
    @agents_by_id = @agents.index_by(&:id)
  end

  def show
    @ticket = Ticket.includes(:customer, :assignee).find(params[:id])
    @messages = @ticket.messages
      .includes(:agent, message_attachments: :attachment)
      .chronological
      .to_a
    @templates = Template.alphabetical
    @agents = Agent.order(:name, :email)

    # Read *before* marking read, or the answer is always false. The thread uses
    # it to accent the newest message when it's something you hadn't seen — the
    # "this is what's new" cue the list's unread dot promised.
    @arrived_unread = @ticket.unread_for?(current_agent)

    mark_read
  end

  def update
    @ticket = Ticket.find(params[:id])
    @ticket.update!(ticket_params)

    redirect_back fallback_location: ticket_path(@ticket)
  end

  private

  def ticket_params
    params.expect(ticket: [:state, :assignee_id])
  end

  # A query only becomes a search once it can mean something. One character
  # matches most of the table, so below the floor the list stays as it was and
  # the box just holds what you have typed so far.
  def searching?
    @query.present? && @query.length >= Customer::MIN_SEARCH_LENGTH
  end
  helper_method :searching?

  def filtered_tickets
    scope = Ticket.with_read_state_for(current_agent)
      .includes(:customer, :assignee)
      .recent_first
      .limit(LIST_LIMIT)

    # A subquery, not joins(:messages). with_read_state_for LEFT JOINs
    # ticket_reads and selects an extra column; joining messages as well would
    # multiply a ticket by its matching messages, and the DISTINCT you would
    # reach for to fix that collides with that select list.
    scope = scope.where(id: @matches.keys) if searching?

    scope = scope.where(state: STATE_FILTERS.fetch(@state_filter)) if @state_filter

    case @assignee_filter
    when nil then scope
    when "me" then scope.assigned_to(current_agent)
    when "unassigned" then scope.unassigned
    else scope.where(assignee_id: @assignee_filter)
    end
  end

  # The row preview. Normally the newest message's excerpt; in a search, the
  # message that actually matched.
  #
  # That swap is the whole reason search needed a message id and not just a
  # ticket id. Previewing the newest message in a result list shows you "Thanks,
  # that worked" under a hit for "smtp_tls", and you cannot see why the ticket
  # is in your results.
  #
  # Fetched in one query for the whole page and indexed by ticket — ascending
  # order means the last write of each key wins, which is the newest message.
  # Search returns exactly one message per ticket, so there is nothing to win.
  #
  # Deliberately a narrow select: Message#body decompresses a blob, and nothing
  # on this screen wants it.
  def latest_messages_for(tickets)
    return {} if tickets.empty?

    scope = Message
      .where(ticket_id: tickets.map(&:id))
      .select(:id, :ticket_id, :direction, :agent_id, :body_excerpt, :sent_at)

    return scope.where(id: @matches.values).index_by(&:ticket_id) if searching?

    scope.order(:sent_at, :id).index_by(&:ticket_id)
  end

  # {customer_id => {"open" => 2, "closed" => 9}} for the People section, in one
  # query rather than two per person.
  def ticket_counts_for(customers)
    return {} if customers.empty?

    Ticket.where(customer_id: customers.map(&:id))
      .group(:customer_id, :state)
      .count
      .each_with_object(Hash.new { |h, k| h[k] = Hash.new(0) }) do |((id, state), n), out|
        out[id][state] = n
      end
  end

  # Marking read is a write on a GET, which the database selector routes to the
  # read-only replica. TicketRead.mark_read! asks for the writing role itself,
  # so there is deliberately no wrap here — see the note on that method.
  def mark_read
    @ticket.mark_read!(current_agent)
  end
end
