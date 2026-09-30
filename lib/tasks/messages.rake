# frozen_string_literal: true

namespace :messages do
  desc "Recompute the stored excerpt of every inbound message from its full body"
  task reexcerpt: :environment do
    # body_excerpt is worked out once, at ingest, and stored: it is what the
    # thread shows above "Show quoted text", what the ticket list previews and
    # what search indexes. When the rule that makes it changes, messages that
    # arrived under the old rule keep the old excerpt until this is run. The
    # full body is always stored, so nothing is lost either way, and a message
    # whose excerpt comes out the same is left alone. The messages_fts update
    # trigger re-indexes the ones that change.
    body = Struct.new(:text, :html)
    changed = 0

    Message.inbound.find_each do |message|
      excerpt = Ingest::Inbound.excerpt_for(body.new(message.body_text, message.body_html))
      next if excerpt == message.body_excerpt

      message.update_columns(body_excerpt: excerpt)
      changed += 1
      puts "  message #{message.id} (ticket #{message.ticket_id})"
    end

    puts "Recomputed #{changed} excerpt(s)."
  end
end
