module ApplicationHelper
  # Modernist marks the current item by weight and ink rather than by a pill, a
  # background or an underline. Active and inactive are mutually exclusive class
  # sets rather than a base plus a modifier, because `text-ink` and `text-soft`
  # have equal specificity — appending one to the other would let stylesheet
  # order decide the winner instead of us.
  def chip_class(active)
    if active
      "text-ink font-semibold"
    else
      "text-soft hover:text-ink"
    end
  end

  # The address customers write to. Single mailbox by design — multiple inboxes
  # are out of scope for v1 (docs/architecture.md).
  def mailbox_address
    ENV.fetch("SPOOL_MAILBOX", "support@example.com")
  end
end
