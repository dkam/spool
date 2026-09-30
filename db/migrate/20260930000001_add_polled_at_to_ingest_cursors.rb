class AddPolledAtToIngestCursors < ActiveRecord::Migration[8.1]
  def change
    # When the source was last read successfully, whether or not it had
    # anything new. updated_at only moves when mail does, so on a quiet day it
    # can't tell a poller that is running from one that stopped — and one that
    # stopped went unnoticed for six weeks. This is what the header checks.
    add_column :ingest_cursors, :polled_at, :datetime
  end
end
