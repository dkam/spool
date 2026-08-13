module TicketsHelper
  # The column stores three states; the design shows the customer-facing reading
  # of them. "pending" means the ball is with the customer — saying so is worth
  # the extra width.
  STATE_LABELS = {
    "open" => "Open",
    "pending" => "Waiting on customer",
    "closed" => "Closed"
  }.freeze

  # The filter chips are terse — they sit in a row of eight and the long form
  # would wrap.
  STATE_FILTER_LABELS = {"open" => "Open", "waiting" => "Waiting", "closed" => "Closed"}.freeze

  def ticket_state_label(ticket)
    STATE_LABELS.fetch(ticket.state, ticket.state.humanize)
  end

  def ticket_assignee_label(ticket)
    return "Unassigned" if ticket.assignee_id.nil?
    return "You" if ticket.assignee_id == current_agent&.id

    # First name only: the meta column is 132px and a full name wraps onto two
    # lines, which breaks the row rhythm the list depends on.
    ticket.assignee.display_name.split(/\s+/).first
  end

  # The prose form, for the ticket header's "Open · assigned to you" line.
  def assignment_phrase(ticket)
    return "unassigned" if ticket.assignee_id.nil?
    return "assigned to you" if ticket.assignee_id == current_agent&.id

    "assigned to #{ticket.assignee.display_name}"
  end

  def ticket_subject(ticket)
    ticket.subject.presence || "(no subject)"
  end

  # Relative for the first week, then an absolute date — the design's ladder is
  # "12 min / 4 hrs / Yesterday / 3 days / 18 Jun".
  def ticket_time(time)
    return "—" if time.blank?

    now = Time.current
    seconds = now - time
    return l(time.to_date, format: :short) if seconds.negative?

    if seconds < 1.minute
      "just now"
    elsif seconds < 1.hour
      "#{(seconds / 1.minute).floor} min"
    elsif time.to_date == now.to_date
      "#{(seconds / 1.hour).floor} hrs"
    elsif time.to_date == now.to_date - 1
      "Yesterday"
    elsif seconds < 7.days
      "#{(seconds / 1.day).floor} days"
    else
      time.strftime("%-d %b")
    end
  end

  # Thread timestamps carry the weekday, which is how people remember a
  # conversation. Past a week the weekday stops helping and the date takes over.
  def message_time(time)
    return "" if time.blank?

    if time > 6.days.ago
      time.strftime("%a %H:%M")
    else
      time.strftime("%-d %b %H:%M")
    end
  end

  # An email body is either a text/plain rendering or an HTML one; both arrive
  # from outside and neither is trustworthy.
  #
  # The text part wins when both exist. It is what the sender's mailer chose as
  # the plain rendering of the same content, it quote-strips cleanly, and it
  # never smuggles in a stylesheet. HTML is the fallback for HTML-only mail.
  #
  # For text we show `body_excerpt` — the reply with its quoted history stripped
  # — and hand the remainder to the "Show quoted text" disclosure. For HTML the
  # quoted history is structural (a <blockquote>, a <div class="gmail_quote">,
  # or nothing at all), and splitting it back out reliably isn't achievable, so
  # HTML bodies render whole and get no disclosure.
  def message_body(message)
    text = message.body_excerpt.presence || message.body_text
    if text.present?
      simple_format(text, {class: "mb-3.5 last:mb-0"}, sanitize: true)
    elsif message.body_html.present?
      inline_images(sanitize_email_html(message.body_html), message)
    else
      tag.p("(no content)", class: "text-faint")
    end
  end

  # The quoted block hidden behind the disclosure, or nil when there isn't one.
  # Only meaningful for text bodies — see #message_body.
  def quoted_history(message)
    full = message.body_text
    excerpt = message.body_excerpt
    return nil if full.blank? || excerpt.blank?

    full.sub(excerpt, "").strip.presence
  end

  # The ticket properties panel: X-Spool-Meta-* headers merged across the
  # thread's inbound messages, later messages winning a key. In practice a
  # form-opened ticket carries them all on its first message; the merge just
  # means a follow-up that re-reports (a new IP, say) shows the current value.
  def ticket_spool_meta(messages)
    messages.select(&:inbound?).reduce({}) { |merged, message| merged.merge(message.spool_meta) }
  end

  META_LABEL_ACRONYMS = {"ip" => "IP", "url" => "URL", "id" => "ID"}.freeze

  # "product-url" → "Product URL", "access-type" → "Access Type".
  def spool_meta_label(key)
    key.split("-").map { |word| META_LABEL_ACRONYMS[word] || word.capitalize }.join(" ")
  end

  # Who wrote a thread entry. Inbound carries its own sender name from the mail
  # headers; outbound and notes are attributed to their agent, and to "You" when
  # that agent is the one reading.
  def message_author(message)
    if message.inbound?
      message.from_name.presence || message.from_email.presence || "Customer"
    elsif message.agent_id == current_agent&.id
      "You"
    else
      message.agent&.display_name.presence || "Spool"
    end
  end

  # The row preview: the newest message's excerpt, attributed when it came from
  # our side. Without the attribution an agent can't tell at a glance whether
  # the last word was the customer's or ours, which is the single most useful
  # thing a list row can tell them.
  def preview_text(message, agents_by_id)
    return "" if message.nil?

    text = message.body_excerpt.to_s.squish
    return text if message.inbound? || text.blank?

    author =
      if message.agent_id == current_agent&.id
        "You"
      else
        agents_by_id[message.agent_id]&.display_name&.split(/\s+/)&.first
      end

    author.present? ? "#{author}: #{text}" : text
  end

  private

  # A restrictive allowlist. Note what is absent: `style` and `class`, so a
  # sender's CSS can't leak into the surrounding page or fight the dark theme;
  # `script`, `iframe`, `object` and `form` for the obvious reasons.
  EMAIL_TAGS = %w[
    p br div span strong b em i u s a ul ol li dl dt dd
    blockquote pre code h1 h2 h3 h4 h5 h6 hr
    table thead tbody tfoot tr td th img
  ].freeze

  EMAIL_ATTRIBUTES = %w[href src alt title colspan rowspan].freeze

  def sanitize_email_html(html)
    # sanitize drops a disallowed tag but keeps its inner text, which turns a
    # <style> block or <title> into a page of visible CSS above the message.
    # Elements whose content is never prose have to go entirely, first.
    html = html.gsub(%r{<(script|style|title|head)[^>]*>.*?</\1>}mi, " ")
    sanitize(html, tags: EMAIL_TAGS, attributes: EMAIL_ATTRIBUTES)
  end

  # An HTML mail references its inline images as `cid:<content-id>`, which means
  # nothing to a browser. Repoint each at the download action for the join row
  # carrying that content id, and drop the ones with no match rather than
  # leaving a broken image in the thread.
  def inline_images(html, message)
    return html unless html.include?("cid:")

    fragment = Nokogiri::HTML5.fragment(html)
    by_content_id = message.message_attachments.index_by(&:content_id)

    fragment.css("img[src^='cid:']").each do |img|
      join = by_content_id[img["src"].to_s.delete_prefix("cid:")]

      if join
        img["src"] = attachment_path(join)
      else
        img.remove
      end
    end

    # Safe to mark: the input was sanitized above and Nokogiri re-serialises it.
    fragment.to_html.html_safe
  end
end
