class Customer < ApplicationRecord
  has_many :tickets, dependent: :destroy

  validates :email, presence: true, uniqueness: {case_sensitive: false}

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }

  # Called from the ingest path, which can process the same sender concurrently
  # from two workers. The unique index is the real guard; the rescue turns the
  # loser of that race into a read instead of a 500.
  def self.find_or_create_by_email!(email, name: nil)
    normalized = email.to_s.strip.downcase

    customer = find_by(email: normalized)
    if customer
      # Only fill a blank name. A display name from a mail header is weak
      # evidence, and overwriting one an agent has corrected would undo them.
      customer.update!(name: name) if customer.name.blank? && name.present?
      return customer
    end

    create!(email: normalized, name: name)
  rescue ActiveRecord::RecordNotUnique
    find_by!(email: normalized)
  end

  def display_name
    name.presence || email
  end

  # Anything shorter matches most of the table and answers nothing.
  MIN_SEARCH_LENGTH = 2

  # LIKE rather than FTS5, and the reason is capability rather than cost.
  #
  # What someone typing into a search box wants from an address is *infix*
  # matching: "ilne" should find "Milne", "field" should find
  # "dana@fieldworks.co". FTS5 only does prefix — `field*` matches a token that
  # starts with it — so it cannot answer either of those without the trigram
  # tokeniser. There is also nowhere to put customers in messages_fts: it is an
  # external-content table keyed content_rowid='id' on messages, so the rowid
  # space is already spoken for.
  #
  # A full scan of a few thousand short rows with no join costs nothing here.
  def self.search(query, limit: 5)
    term = query.to_s.strip
    return none if term.length < MIN_SEARCH_LENGTH

    # % and _ are LIKE wildcards; a customer searching for "a_b" means those
    # three characters.
    pattern = "%#{term.gsub(/[\\%_]/) { |c| "\\#{c}" }}%"

    where("customers.name LIKE :p ESCAPE '\\' OR customers.email LIKE :p ESCAPE '\\'", p: pattern)
      .left_joins(:tickets)
      .group(:id)
      # Most recently in touch first. Ranking five results by match quality
      # would be theatre; "who wrote most recently" is a fact and it is useful.
      .order(Arel.sql("MAX(tickets.last_activity_at) IS NULL, MAX(tickets.last_activity_at) DESC"))
      .limit(limit)
  end
end
