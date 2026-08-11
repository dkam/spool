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

  # Where the header's search form sends its results.
  #
  # On the inbox the results land in the frame that is already showing a list,
  # which is what makes search-as-you-type possible: the frame swaps, the header
  # is untouched, and the caret stays in the box. Everywhere else there is no
  # such frame, so the form does a full navigation to the inbox instead — and
  # the controller only types ahead when it has a frame to type into, because
  # navigating the whole page on every keystroke would throw the caret away.
  def search_frame_target
    (controller_name == "tickets" && action_name == "index") ? "ticket_list" : "_top"
  end
end
