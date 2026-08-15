class Ticket < ApplicationRecord
  STATES = %w[open pending closed].freeze

  belongs_to :customer
  belongs_to :assignee, class_name: "Agent", optional: true, inverse_of: :tickets

  has_many :messages, dependent: :destroy
  has_many :ticket_reads, dependent: :delete_all
  has_many :ticket_tags, dependent: :delete_all
  has_many :tags, through: :ticket_tags

  validates :state, presence: true, inclusion: {in: STATES}

  # Live updates, as Turbo 8 page refreshes: any commit to a ticket row tells
  # subscribed browsers to re-fetch what they're looking at, and morphing keeps
  # the result calm. The ticket row is the one reliable signal — every event
  # (inbound mail, reply, note, state or assignee change) writes it, so there
  # is nothing to broadcast from Message.
  #
  # Synchronous rather than *_later on purpose: a refresh broadcast is one
  # small insert into the cable database, and routing it through the job queue
  # would make "the screen is live" depend on a worker being up.
  #
  # :tickets is the list screen's stream; self is the ticket's own. An update
  # feeds both — a reply must move the list row *and* the open thread.
  after_create_commit -> { broadcast_refresh_to :tickets }
  after_update_commit -> {
    broadcast_refresh_to :tickets
    broadcast_refresh
  }

  scope :open_state, -> { where(state: "open") }
  scope :pending, -> { where(state: "pending") }
  scope :closed, -> { where(state: "closed") }
  scope :unresolved, -> { where(state: %w[open pending]) }
  scope :recent_first, -> { order(last_activity_at: :desc) }
  scope :assigned_to, ->(agent) { where(assignee: agent) }
  scope :unassigned, -> { where(assignee_id: nil) }

  # The unique index on ticket_tags means a name matches at most one join row
  # per ticket, so this join can't multiply rows — safe to compose with
  # .with_read_state_for, whose select list a DISTINCT would collide with.
  scope :tagged, ->(name) {
    joins(:tags).where(tags: {name: Tag.normalize_value_for(:name, name)})
  }

  # NOT EXISTS for the same reason as .unread_for: a ticket with *other* tags
  # must still count as not-tagged, and it also keeps the ticket_tags join out
  # of the outer query's row count.
  scope :not_tagged, ->(name) {
    where.not(
      TicketTag
        .joins(:tag)
        .where(tags: {name: Tag.normalize_value_for(:name, name)})
        .where("ticket_tags.ticket_id = tickets.id")
        .arel.exists
    )
  }

  # A ticket is read for an agent when a ticket_reads row exists whose
  # last_read_at is at least as recent as the ticket's last_activity_at.
  # Unread is the negation — which correctly covers "never opened" (no row) and
  # "read, then the customer replied" in one condition.
  #
  # NOT EXISTS rather than a LEFT JOIN: the agent predicate has to sit inside
  # the join condition, and expressing that as a WHERE on a left join would
  # filter out the very rows (other agents') that make the ticket look unread.
  scope :unread_for, ->(agent) {
    next none if agent.nil?

    where.not(
      TicketRead
        .where(agent_id: agent.id)
        .where("ticket_reads.ticket_id = tickets.id")
        .where("ticket_reads.last_read_at >= tickets.last_activity_at")
        .arel.exists
    )
  }

  # The tag appended to outbound subjects so a reply whose client dropped
  # In-Reply-To and References can still be threaded. Last-resort matcher —
  # see Ingest::Threader.
  SUBJECT_TAG = /\[#(\d+)\]/

  def subject_tag
    "[##{id}]"
  end

  def tagged_subject
    base = subject.presence || "(no subject)"
    base.match?(SUBJECT_TAG) ? base : "#{base} #{subject_tag}"
  end

  # The list screen's read state, in the same query as the tickets themselves.
  # Each row gains a `last_read_at` attribute (nil when never opened), so
  # #unread? answers without touching the database.
  #
  # The agent predicate has to live in the JOIN's ON clause. Putting it in a
  # WHERE against a LEFT JOIN would discard rows whose only ticket_reads match
  # belongs to a different agent — i.e. exactly the tickets that should show as
  # unread — silently turning "unread for me" into "unread for everyone".
  scope :with_read_state_for, ->(agent) {
    next all if agent.nil?

    joins(sanitize_sql_array([<<~SQL, agent.id]))
      LEFT OUTER JOIN ticket_reads
        ON ticket_reads.ticket_id = tickets.id
       AND ticket_reads.agent_id = ?
    SQL
      .select("tickets.*", "ticket_reads.last_read_at AS last_read_at")
  }

  # Only meaningful on a relation loaded through .with_read_state_for. Raises
  # rather than quietly firing a query per row, which is the bug this scope
  # exists to prevent.
  def unread?
    unless has_attribute?(:last_read_at)
      raise ArgumentError,
        "Ticket#unread? needs .with_read_state_for(agent); use #unread_for?(agent) for a single ticket"
    end
    return false if last_activity_at.nil?

    self[:last_read_at].nil? || self[:last_read_at] < last_activity_at
  end

  # Single-ticket read check, for the detail page. Use TicketRead.timestamps_for
  # when rendering a list — this is one query per call by design, and a list
  # should not make N of them.
  def unread_for?(agent)
    return false if agent.nil? || last_activity_at.nil?

    read_at = ticket_reads.where(agent_id: agent.id).pick(:last_read_at)
    read_at.nil? || read_at < last_activity_at
  end

  def mark_read!(agent)
    TicketRead.mark_read!(agent: agent, ticket: self)
  end

  # Tags describe the conversation and are orthogonal to state — a spam ticket
  # that turns out to be a real customer goes back into the inbox without
  # losing where it was in open/pending/closed.
  #
  # Both writes touch the ticket row when they change anything, because the row
  # is the broadcast signal (see the callbacks above) and a tag change moves
  # the ticket between list views.
  def tag!(name)
    tag = Tag.named!(name)
    ticket_tags.create!(tag: tag)
    touch
  rescue ActiveRecord::RecordNotUnique
    # Already tagged — by a concurrent worker, or an agent double-clicking.
  end

  def untag!(name)
    tag = Tag.find_by(name: Tag.normalize_value_for(:name, name))
    return if tag.nil?

    touch if ticket_tags.where(tag: tag).delete_all.positive?
  end

  def tagged?(name)
    normalized = Tag.normalize_value_for(:name, name)
    return tags.any? { |tag| tag.name == normalized } if tags.loaded?

    tags.exists?(name: normalized)
  end

  def spam? = tagged?(Tag::SPAM)

  # The two halves of "this is spam": hide the ticket, and stop the next one
  # from landing in the inbox at all — Ingest::Inbound tags mail from a
  # blocked customer on arrival. One method so the UI and MCP can't apply half.
  #
  # Deliberately not a rejection: the mail is still ingested and stored, so a
  # wrong block costs a ticket sitting in the spam view, not a customer's
  # email vanishing without trace.
  def mark_spam!
    transaction do
      tag!(Tag::SPAM)
      customer.block!
    end
  end

  def unmark_spam!
    transaction do
      untag!(Tag::SPAM)
      customer.unblock!
    end
  end

  # The message a reply should thread onto: the most recent one that actually
  # went over email. Internal notes are skipped — they have no Message-ID the
  # customer's client has ever seen, so threading a reply to one would break
  # the chain.
  def last_emailed_message
    messages.emailed.chronological.last
  end

  # Inbound mail reopens a ticket: a customer replying to something an agent
  # considered finished is exactly the case that must not stay buried under a
  # closed filter.
  def record_inbound_activity!(at)
    update!(state: "open", last_activity_at: at)
  end

  # Sending flips to pending — the ball is with the customer.
  def record_outbound_activity!(at)
    update!(state: "pending", last_activity_at: at)
  end
end
