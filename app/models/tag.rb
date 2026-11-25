class Tag < ApplicationRecord
  # The one tag with behaviour attached: Ticket#mark_spam! applies it and
  # blocks the sender, and the ticket list hides tickets carrying it unless
  # asked. Every other tag is a plain label.
  SPAM = "spam"

  # A plain label, but one Spool applies itself: Ticket#reply_refused! adds
  # it when the customer's mail server refuses a reply's address. Nothing
  # hides it and nothing happens on removing it.
  UNDELIVERABLE = "undeliverable"

  has_many :ticket_tags, dependent: :delete_all
  has_many :tickets, through: :ticket_tags

  validates :name, presence: true, uniqueness: {case_sensitive: false}

  # Lowercase-only, so "Spam", "spam " and "spam" are one tag rather than three
  # chips on the filter row.
  normalizes :name, with: ->(n) { n.to_s.strip.downcase }

  # Called from the ingest path, which can tag the same name from two workers.
  # Same shape as Customer.find_or_create_by_email! and for the same reason.
  def self.named!(name)
    normalized = normalize_value_for(:name, name)
    find_by(name: normalized) || create!(name: normalized)
  rescue ActiveRecord::RecordNotUnique
    find_by!(name: normalized)
  end
end
