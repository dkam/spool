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
end
