# frozen_string_literal: true

module Outbound
  # The transport looked at the exact send and said no — bad credentials, an
  # unknown sending domain, a recipient the provider refuses. The same bytes
  # would be refused the same way on retry, so the consumer buries the job
  # rather than cycling it five times first. Each transport raises a subclass
  # (Outbound::Http::Rejected, Outbound::Smtp::Rejected) carrying transport
  # detail; the consumer rescues the base.
  class Rejected < StandardError; end

  # The refusal that is about the recipient's address — it doesn't exist, its
  # domain doesn't, it's disabled — rather than about us. Nothing on our side
  # fixes it, so Outbound::Delivery marks the reply undeliverable instead of
  # leaving it for a backfill that would only send it back to the same
  # address. The message is the receiving server's own reply, for the thread.
  class RecipientRejected < Rejected; end
end
