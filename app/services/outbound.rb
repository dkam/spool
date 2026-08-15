# frozen_string_literal: true

module Outbound
  # The transport looked at the exact send and said no — bad credentials, an
  # unknown sending domain, a recipient the provider refuses. The same bytes
  # would be refused the same way on retry, so the consumer buries the job
  # rather than cycling it five times first. Each transport raises a subclass
  # (Outbound::Http::Rejected, Outbound::Smtp::Rejected) carrying transport
  # detail; the consumer rescues the base.
  class Rejected < StandardError; end
end
