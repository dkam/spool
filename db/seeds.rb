# Development seed data.
#
# Reproduces the content from the Claude Design source (Spool.dc.html) so the
# three screens can be looked at with something realistic in them — a thread
# with an internal note, quoted history, an attachment and a mix of read and
# unread. See docs/ui.md.
#
# Idempotent: keyed on natural keys (email, message_id, template name), so
# running it twice changes nothing. Times are relative to now, so the list's
# "12 min / 4 hrs / Yesterday" ladder is always exercised.

# Seeds run outside the DatabaseSelector, so ask for the writing role rather
# than depending on whatever the default happens to be.
ApplicationRecord.writing do
  # --- Agents ---------------------------------------------------------------
  # Matches the stand-in Authentication#development_agent provisions, so the
  # seeded "you" and the logged-in "you" are the same row.
  you = Agent.find_or_provision!(
    oidc_sub: "dev-open-mode",
    email: ENV.fetch("SPOOL_DEV_AGENT_EMAIL", "dev@localhost"),
    name: "Development Agent"
  )

  ines = Agent.find_or_provision!(
    oidc_sub: "seed-ines",
    email: "ines@northgate.dev",
    name: "Ines Adler"
  )

  # --- Templates ------------------------------------------------------------
  [
    ["Ask for logs", "Delivery log and config dump",
      "Could you send me the last twenty lines of the delivery log and the output of spool config get smtp? That will tell us which mode it fell back to."],
    ["Pin smtp_tls to starttls", "2.4 migration",
      "That is the whole problem — 2.4 rewrote smtp_tls to auto during the migration. Set it back with:\n\nspool config set smtp_tls starttls\n\nThen restart the queue whenever it suits you. Nothing in the outbox will be lost in the meantime."],
    ["Waiting on customer", nil,
      "No rush — I will leave this open on my side until you have had a chance to look."],
    ["Resolved — closing", nil,
      "Glad that sorted it, {{customer.name}}. I am closing this ticket, but replying to this email will reopen it if anything comes back."]
  ].each do |name, subject, body|
    Template.find_or_initialize_by(name: name).update!(subject: subject, body: body)
  end

  # --- Helpers --------------------------------------------------------------
  # Inbound rows are written directly rather than through Message.compose!,
  # which exists for the outbound side. A seeded inbound message stands in for
  # something Ingest::Inbound would have produced.
  add_inbound = lambda do |ticket, from_name, from_email, text, at, quoted: nil|
    # Keyed on a digest of the ticket and the text, not on `at` — the timestamps
    # here are relative to now and so differ on every run, which would make the
    # Message-ID new each time and quietly duplicate the whole thread.
    digest = Digest::SHA256.hexdigest("#{ticket.id}\0#{text}")[0, 16]
    id = "<seed-#{digest}@#{from_email.split("@").last}>"
    next Message.find_by(message_id: id) if Message.exists?(message_id: id)

    full = quoted ? "#{text}\n\n#{quoted}" : text
    document = JSON.generate({"text" => full, "html" => nil})

    Message.create!(
      ticket: ticket, direction: "inbound", message_id: id,
      from_name: from_name, from_email: from_email,
      subject: ticket.subject, sent_at: at,
      body: document, body_excerpt: text, raw_size: document.bytesize
    )
  end

  # compose! stamps sent_at as "now" and moves the ticket's state, which is
  # right for the app and wrong for a fixture that needs to sit at a chosen
  # point in the past. Correct both afterwards.
  add_reply = lambda do |ticket, agent, text, at, direction: "outbound"|
    # compose! issues its own Message-ID, so there's no stable id to key on —
    # the body is what identifies a seeded reply. Same reason as add_inbound:
    # `at` moves on every run and cannot be the key.
    next if ticket.messages.where(direction: direction, body_excerpt: text).exists?

    message = Message.compose!(ticket: ticket, agent: agent, text: text, direction: direction)
    message.update!(sent_at: at)
    message
  end

  build = lambda do |email:, name:, subject:, state:, at:, assignee: nil, notes: nil|
    customer = Customer.find_or_create_by_email!(email, name: name)
    customer.update!(notes: notes) if notes && customer.notes.blank?

    ticket = customer.tickets.find_or_create_by!(subject: subject)
    ticket.update!(state: state, assignee: assignee, last_activity_at: at)
    ticket
  end

  # --- The worked example ---------------------------------------------------
  # The design's ticket #1042: an inbound problem, a reply, an internal note,
  # then a follow-up with an attachment and quoted history.
  dana = build.call(
    email: "dana@fieldworks.co", name: "Dana Whitmore",
    subject: "Can't connect SMTP after upgrade to 2.4",
    state: "open", assignee: you, at: 12.minutes.ago,
    notes: "Prefers email over calls. Runs two instances — production on box one, staging on box two; always ask which one before giving a command."
  )

  add_inbound.call(
    dana, "Dana Whitmore", "dana@fieldworks.co",
    "I upgraded our instance to 2.4 last night and since then nothing leaves the outbox. Inbound mail is fine — new tickets keep arriving — but every reply sits in the queue and retries.\n\n" \
    "The log line I keep getting is smtp: 535 authentication failed. Nothing changed on the mail server side as far as I know. We are on Postfix, port 587, STARTTLS.",
    3.hours.ago
  )

  add_reply.call(
    dana, you,
    "Thanks Dana — 2.4 rewrites the TLS setting during migration, so this is likely a config change rather than your mail server.\n\n" \
    "Could you send me the output of spool config get smtp and the last twenty lines of the delivery log? That will tell us which mode it fell back to.",
    2.hours.ago
  )

  add_reply.call(
    dana, ines,
    "Same as #1031. The 2.4 migration rewrites smtp_tls to auto, which downgrades to plain auth on 587. If that is what she sends back, tell her to pin it to starttls — no need to escalate.",
    100.minutes.ago,
    direction: "note"
  )

  # The newest message, with the quoted history the disclosure hides and the
  # attachment the thread lists.
  latest = add_inbound.call(
    dana, "Dana Whitmore", "dana@fieldworks.co",
    "Attached. It says smtp_tls = auto, which is not what we had before — it was starttls when we set it up in March.\n\n" \
    "Happy to change it, I just want to be sure that is the whole problem before I restart the queue in working hours.",
    12.minutes.ago,
    quoted: "On Tue at 09:31, Spool Support wrote:\n" \
            "> Thanks Dana — 2.4 rewrites the TLS setting during migration, so this is likely a config change rather than your mail server.\n" \
            "> Could you send me the output of spool config get smtp and the last twenty lines of the delivery log?"
  )

  # compose! moved the ticket to "pending" and stamped last_activity_at as now —
  # correct for the app, wrong for a fixture that has a customer reply arriving
  # after our reply. Put it back where the design has it.
  dana.update!(state: "open", last_activity_at: 12.minutes.ago)

  if latest && latest.message_attachments.empty?
    config_dump = <<~TXT
      # spool config get smtp
      smtp_host      = mail.fieldworks.co
      smtp_port      = 587
      smtp_tls       = auto
      smtp_username  = spool@fieldworks.co
      smtp_auth      = plain
    TXT

    blob = Attachment.store!(config_dump, content_type: "text/plain")
    MessageAttachment.create!(message: latest, attachment: blob, filename: "smtp-config.txt")
  end

  # --- The rest of the inbox ------------------------------------------------
  rest = [
    {email: "tomas@berg-studio.se", name: "Tomas Berg",
     subject: "Refund for duplicate invoice 4471", state: "open", assignee: nil, at: 41.minutes.ago,
     inbound: "We were charged twice on the 3rd — same amount, same card. Could you refund the second one?"},

    {email: "priya@northgate.dev", name: "Priya Raman",
     subject: "Feature request: per-mailbox signatures", state: "pending", assignee: ines, at: 2.hours.ago,
     inbound: "Any chance of a different signature per mailbox? We run two and they need different footers.",
     reply: "Noted — I have added it to the list. I will write back when there is something to try."},

    {email: "greg@harbourline.io", name: "Greg Mackay",
     subject: "Licence key rejected on the second server", state: "open", assignee: ines, at: 4.hours.ago,
     inbound: "Still failing after the restart. The key works on box one and not on box two, same file."},

    {email: "h.roussel@atelier-nord.fr", name: "Hélène Roussel",
     subject: "Attachments over 10 MB are silently dropped", state: "open", assignee: you, at: 26.hours.ago,
     inbound: "No error, no bounce — the customer just never receives the file. I can reproduce it every time."},

    {email: "sam@okonjo.dev", name: "Sam Okonjo",
     subject: "Docs: the webhook payload example is stale", state: "pending", assignee: you, at: 2.days.ago,
     inbound: "The webhook example in the docs does not match what actually arrives.",
     reply: "Thanks for the catch. Which page were you looking at — the 2.3 or the 2.4 reference?"},

    {email: "wei@linworks.cn", name: "Wei Lin",
     subject: "How do I export every ticket as mbox?", state: "closed", assignee: ines, at: 3.days.ago,
     inbound: "Is there a way to get everything out as mbox?",
     reply: "spool export --format mbox --all writes one file per mailbox. Closing this — shout if it misbehaves."},

    {email: "priya@northgate.dev", name: "Priya Raman",
     subject: "Onboarding call follow-up", state: "closed", assignee: you, at: 5.days.ago,
     inbound: "Could you send over what we talked about on the call?",
     reply: "Here are the two config files we talked through, plus the migration note."}
  ]

  rest.each do |row|
    ticket = build.call(
      email: row[:email], name: row[:name], subject: row[:subject],
      state: row[:state], assignee: row[:assignee], at: row[:at]
    )

    add_inbound.call(ticket, row[:name], row[:email], row[:inbound], row[:at] - 1.hour)
    add_reply.call(ticket, ticket.assignee || you, row[:reply], row[:at]) if row[:reply]

    # compose! moved state and last_activity_at; put the fixture back where it
    # is meant to sit.
    ticket.update!(state: row[:state], last_activity_at: row[:at])
  end

  # --- Dana's history, for the customer screen ------------------------------
  [
    ["Queue stuck after a power cut", "The retry loop cleared once the lock file was removed.", 54.days.ago],
    ["Add a second agent seat", "Done — Marek has access from today.", 101.days.ago],
    ["Import from the old mailbox", "The mbox import finished with 2,140 tickets and no errors.", 124.days.ago],
    ["Trial questions before self-hosting", "Yes, one binary and a Postgres URL is all it needs.", 150.days.ago]
  ].each do |subject, reply, at|
    ticket = build.call(
      email: "dana@fieldworks.co", name: "Dana Whitmore",
      subject: subject, state: "closed", assignee: you, at: at
    )

    add_inbound.call(ticket, "Dana Whitmore", "dana@fieldworks.co", "#{subject}?", at - 1.hour)
    add_reply.call(ticket, you, reply, at)
    ticket.update!(state: "closed", last_activity_at: at)
  end

  # Dana's ticket is the one that should look new; everything else has been
  # seen, so the list shows a believable mix rather than all-unread.
  #
  # Read state is set explicitly in both directions — marking the rest read and
  # clearing Dana's — so re-running the seeds after browsing around restores the
  # demo rather than leaving whatever you happened to open still read.
  Ticket.find_each { |ticket| ticket.mark_read!(you) }
  dana.ticket_reads.delete_all

  puts "Seeded #{Ticket.count} tickets, #{Message.count} messages, " \
       "#{Customer.count} customers, #{Template.count} templates."
end
