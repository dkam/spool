class Tag < ApplicationRecord
  # The one tag with behaviour attached: Ticket#mark_spam! applies it and
  # blocks the sender, and the ticket list hides tickets carrying it unless
  # asked. Every other tag is a plain label.
  SPAM = "spam"

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
