class TicketRead < ApplicationRecord
  belongs_to :agent
  belongs_to :ticket

  validates :last_read_at, presence: true

  # An upsert rather than find_or_initialize: opening a ticket is a GET that
  # fires on every page view, sometimes twice (a Turbo prefetch and the real
  # navigation), and the unique index should settle that rather than a
  # RecordNotUnique surfacing to the reader.
  #
  # Wraps itself in the writing role. Marking read is a side effect of a GET —
  # opening a ticket — and a GET is routed to the read-only replica by the
  # database selector, so an unwrapped write here raises ReadOnlyError. Putting
  # the wrap inside the method rather than asking every caller to remember it
  # means the trap can only be sprung once.
  def self.mark_read!(agent:, ticket:, at: Time.current)
    return if agent.nil?

    ApplicationRecord.writing do
      upsert(
        {agent_id: agent.id, ticket_id: ticket.id, last_read_at: at},
        unique_by: [:agent_id, :ticket_id]
      )
    end
  end

  # last_read_at keyed by ticket id, for rendering a list without a query per
  # row. Pass the tickets already loaded for the page.
  def self.timestamps_for(agent, tickets)
    return {} if agent.nil?

    where(agent_id: agent.id, ticket_id: tickets).pluck(:ticket_id, :last_read_at).to_h
  end
end
