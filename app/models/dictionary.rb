class Dictionary < ApplicationRecord
  KINDS = %w[headers body].freeze

  validates :kind, presence: true, inclusion: {in: KINDS}
  validates :version, presence: true, uniqueness: {scope: :kind}
  validates :data, presence: true

  scope :of_kind, ->(kind) { where(kind: kind.to_s) }

  # Promotion is an insert, never an update — existing rows keep pointing at
  # the dictionary they were written with, which stays readable forever.
  def self.promote!(kind:, data:, sample_count: nil)
    next_version = of_kind(kind).maximum(:version).to_i + 1

    create!(kind: kind.to_s, version: next_version, data: data, sample_count: sample_count).tap do
      Compression::DictStore.invalidate_current(kind)
    end
  end

  def self.current(kind)
    of_kind(kind).order(version: :desc).first
  end
end
