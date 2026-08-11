class AttachmentsController < ApplicationController
  # Attachment bytes live in the primary SQLite file rather than Active Storage
  # (docs/architecture.md), so there is no blob URL — this action is the only
  # way to get one out.
  #
  # Keyed on the join row, not the attachment: the filename belongs to the join,
  # and the same deduplicated blob is `logo.png` in one thread and
  # `image001.png` in another.
  def show
    join = MessageAttachment.includes(:attachment).find(params[:id])

    send_data join.attachment.bytes,
      filename: join.filename.presence || "attachment",
      type: join.attachment.content_type.presence || "application/octet-stream",
      # Inline so a cid: image can render in the thread; everything else is a
      # download the browser decides about. `disposition: :attachment` would
      # break inline images.
      disposition: join.inline? ? :inline : :attachment
  end
end
