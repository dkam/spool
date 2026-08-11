class Agent < ApplicationRecord
  has_many :tickets, foreign_key: :assignee_id, dependent: :nullify, inverse_of: :assignee
  has_many :messages, dependent: :nullify
  has_many :ticket_reads, dependent: :delete_all

  validates :oidc_sub, presence: true, uniqueness: true
  validates :email, presence: true, uniqueness: {case_sensitive: false}

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }

  # Agents are provisioned by logging in — there is no invite or admin screen.
  # Access is decided before this is ever called (Spool::Authorization checks
  # the allowlist against the ID token's email), so reaching here means the
  # person is allowed in.
  #
  # Keyed on `sub` rather than email so an address change at the IdP updates the
  # existing agent instead of orphaning their tickets behind a new row.
  def self.find_or_provision!(oidc_sub:, email:, name: nil)
    agent = find_by(oidc_sub: oidc_sub)

    return create!(oidc_sub: oidc_sub, email: email, name: name) unless agent

    # Only write when something actually changed. This runs on every login, and
    # in open mode it once ran on every request — an UPDATE that writes the
    # same values back is a write nonetheless, and writes are the scarce thing
    # in a single-writer SQLite application.
    changes = {}
    changes[:email] = email if email.present? && agent.email != email.to_s.strip.downcase
    changes[:name] = name if name.present? && agent.name != name

    agent.update!(changes) if changes.any?
    agent
  end

  def display_name
    name.presence || email
  end
end
