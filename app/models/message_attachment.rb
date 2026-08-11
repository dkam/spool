class MessageAttachment < ApplicationRecord
  belongs_to :message
  belongs_to :attachment

  # Inline parts carry a Content-ID so a cid: reference in an HTML body can be
  # resolved; ordinary attachments don't.
  scope :inline, -> { where.not(content_id: nil) }
  scope :regular, -> { where(content_id: nil) }

  def inline? = content_id.present?
end
