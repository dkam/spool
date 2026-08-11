class CustomersController < ApplicationController
  def show
    @customer = Customer.find(params[:id])
    @tickets = @customer.tickets
      .with_read_state_for(current_agent)
      .recent_first
      .to_a
    @latest_messages = latest_messages_for(@tickets)
    # A helpdesk team is small enough that loading every agent to resolve
    # preview authorship is one trivial query, and cheaper than joining.
    @agents_by_id = Agent.all.index_by(&:id)
  end

  # Notes autosave from a debounced textarea (see notes_controller.js), so this
  # answers a fetch rather than a form post and has no redirect to offer.
  def update
    @customer = Customer.find(params[:id])
    @customer.update!(customer_params)

    head :no_content
  end

  private

  def customer_params
    params.expect(customer: [:notes])
  end

  def latest_messages_for(tickets)
    return {} if tickets.empty?

    Message
      .where(ticket_id: tickets.map(&:id))
      .select(:id, :ticket_id, :direction, :agent_id, :body_excerpt, :sent_at)
      .order(:sent_at, :id)
      .index_by(&:ticket_id)
  end
end
