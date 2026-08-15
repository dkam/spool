# UI contract

What the views are built against. If you are writing controllers or templates,
this is the page you need; you should not have to read the ingest or compression
code to build a screen.

## Models at a glance

```
Customer 1─┬─* Ticket 1───* Message *───* Attachment
           │       │            │              (via MessageAttachment)
           │       └─* TicketRead *─┐
           │                        │
Agent  ────┴────────────────────────┘   (assignee, message author, reader)
```

## Ticket

```ruby
ticket.customer          # Customer
ticket.assignee          # Agent or nil
ticket.messages          # chronological order via .chronological
ticket.state             # "open" | "pending" | "closed"  (Ticket::STATES)
ticket.subject           # may be nil — fall back to "(no subject)"
ticket.last_activity_at  # the only sort key the list uses
```

Scopes: `open_state`, `pending`, `closed`, `unresolved` (open + pending),
`recent_first`, `assigned_to(agent)`, `unassigned`, `unread_for(agent)`,
`tagged(name)`, `not_tagged(name)`.

`open_state`, not `open` — `open` is taken by `Object#open` and shadowing it in a
scope is a trap.

State transitions go through `record_inbound_activity!(at)` (→ open) and
`record_outbound_activity!(at)` (→ pending), which also touch
`last_activity_at`. Don't set `state` and `last_activity_at` separately.

`ticket.tagged_subject` appends `[#id]` for outbound subjects — that tag is a
threading fallback, so don't strip it from what gets sent.

### Tags

```ruby
ticket.tags               # Tag records; names are lowercase
ticket.tag!("billing")    # created on first use; idempotent
ticket.untag!("billing")  # unknown names are a no-op
ticket.tagged?("billing")
ticket.spam?              # tagged?(Tag::SPAM)
ticket.mark_spam!         # tags spam AND blocks the customer — one transaction
ticket.unmark_spam!       # takes both back
```

Use `mark_spam!`/`unmark_spam!` for spam, never `tag!("spam")` directly — spam
is a paired write and the model owns the pairing. **Every list view must hide
spam** unless the spam tag is the active filter: filter through
`not_tagged(Tag::SPAM)` by default, and keep any count badge on the same scope
as the list it describes. See [tags.md](tags.md).

### Read state

Per-agent, so "unread" means something with more than one person.

```ruby
ticket.unread_for?(current_agent)   # one query — detail page only
ticket.mark_read!(current_agent)    # upsert; safe to call on every view

Ticket.unread_for(current_agent)    # scope, for a filter
TicketRead.timestamps_for(current_agent, @tickets)  # {ticket_id => last_read_at}
```

**For a list, use `TicketRead.timestamps_for`** with the page's tickets and
compare in the view — `unread_for?` in a loop is a query per row.

A ticket is unread when there's no read row, or when `last_read_at` is older
than `last_activity_at` — so a customer replying to a thread you'd read makes it
unread again.

## Message

```ruby
message.direction     # "inbound" | "outbound" | "note"
message.inbound?  message.outbound?  message.note?
message.agent         # author for outbound and notes; nil for inbound
message.from_email    # set for inbound
message.from_name
message.subject
message.sent_at
message.body_excerpt  # quote-stripped plain text — what the list should show
```

Scopes: `chronological`, `inbound`, `outbound`, `notes`, `emailed`
(inbound + outbound).

### Rendering a body

```ruby
message.body_text          # the text/plain rendering, or nil
message.body_html          # the text/html rendering, or nil
message.body_for_display   # html if present, else text
```

**Do not use `message.body`.** It returns a JSON document, not display text —
the blob holds both renderings. See [ingest.md](ingest.md).

`body_html` is attacker-controlled by definition. **Sanitise it.** Rails'
`sanitize` helper with a restrictive allowlist, and remember that a customer's
HTML email will contain `cid:` image references (below) and inline styles that
can escape into the surrounding page if you let them.

### Internal notes

`direction: "note"` shares the thread with the emailed messages. Two
requirements, both day-one:

1. Visually distinct from inbound and outbound.
2. Unmistakably never-emailed. An agent must not be able to glance at a note and
   think the customer saw it.

### Attachments

```ruby
message.attachments             # Attachment records (content-addressed, shared)
message.message_attachments     # the join rows — filename and content_id live here
```

Filename is on the **join**, not the attachment: the same blob arrives as
`logo.png` from one sender and `image001.png` from another.

```ruby
ma.filename
ma.inline?        # true when content_id is set
ma.content_id     # matches a cid: reference in body_html, brackets stripped
ma.attachment.content_type
ma.attachment.byte_size    # uncompressed size
ma.attachment.bytes        # decompressed bytes — for a download action
```

There is no Active Storage and no public URL. Serving an attachment means a
controller action that reads `.bytes` and `send_data`s it.

## Customer

```ruby
customer.tickets
customer.notes          # free-text, agent-editable
customer.display_name   # name, falling back to email
customer.email
customer.blocked?       # their mail still arrives, but lands tagged spam
```

`blocked_at` is set and cleared by `Ticket#mark_spam!` / `#unmark_spam!` — a
view should read it, not write it.

## Agent

```ruby
agent.display_name      # name, falling back to email
agent.email
agent.tickets           # tickets assigned to them (foreign key: assignee_id)
```

No roles. Everyone sees everything.

## Template

```ruby
template.name
rendered = template.render(customer: ticket.customer, agent: current_agent)
rendered[:subject]
rendered[:body]
```

Interpolates `{{customer.name}}`, `{{customer.email}}`, `{{agent.name}}`,
`{{agent.email}}`. An unknown placeholder is left visible rather than blanked,
so the agent can see the mistake before sending.

Templates land in the compose box for the agent to edit. **Never auto-send.**

## Composing a reply or a note

`Message.compose!` is the only supported way to create an outbound message or a
note. Don't build one by hand.

```ruby
Message.compose!(ticket:, agent:, text:)                      # a reply
Message.compose!(ticket:, agent:, text:, direction: "note")   # an internal note
Message.compose!(ticket:, agent:, text:, subject: "…")        # override the subject
```

It owns four things a compose form can't be expected to get right, each of which
breaks something invisible if it's wrong:

1. A Spool-issued `Message-ID`. Both the customer's client threading the reply
   and `LoopGuard` recognising our own mail echoed back depend on it.
2. `in_reply_to` and `references_header`, built from
   `ticket.last_emailed_message` — the last *emailed* message, skipping internal
   notes, which have no Message-ID the customer's client has ever seen.
3. The JSON body envelope.
4. The state transition. A reply calls `record_outbound_activity!` (→ pending);
   a note only touches `last_activity_at`, because an internal note doesn't hand
   the ball back to the customer.

Subject defaults to `ticket.tagged_subject`, so the `[#id]` threading fallback is
present.

**Delivery does not exist yet** (milestone 5). The row is complete and correct;
nothing sends it. When sending lands it hooks onto this same method, so calling
code won't change.

## Writing from a GET

The database selector routes every GET to the reading role, so a write during a
GET raises `ActiveRecord::ReadOnlyError`. Two cases are legitimate and already
handled — marking a ticket read on `#show`, and provisioning the open-mode agent
— and both wrap themselves, so callers need do nothing.

If you add another, wrap it:

```ruby
ApplicationRecord.writing { ... }
```

Better still, put the wrap inside the model method, so it can only be forgotten
once.

**`ApplicationRecord.writing`, never `SomeModel.connected_to(role: :writing)`.**
`prevent_writes` is tracked per connection class. The middleware sets it on
`ActiveRecord::Base`, so switching role on `ApplicationRecord` clears a
different flag from the one the adapter consults: the write still raises while
`ApplicationRecord.current_preventing_writes` reports `false`. It is a genuinely
confusing error. `ApplicationRecord.writing` switches on `ActiveRecord::Base`
and is correct in every environment.

The split is **enabled in test on purpose**. Test is the only environment where
an unwrapped write on a GET actually fails — in development and production the
roles are separate pools, so the write quietly succeeds against the replica
connection and the bug ships. `test/models/writing_role_test.rb` guards this.

## Turbo frames

There is exactly one frame in the app: `ticket_list` on the inbox, wrapping the
filters and the rows together so a filter click swaps both in one request.

A link inside a frame navigates *that frame*. The ticket rows have to leave it:

```erb
<%= link_to ticket_path(ticket), data: { turbo_frame: "_top" } do %>
```

Without that, Turbo looks for a `ticket_list` frame in the `tickets/show`
response, doesn't find one, and replaces the row with "Content missing". If you
add a frame, check every link inside it — and cover it with a test that
*clicks*, not one that `visit`s the destination directly.

## Ticket list filters

The list is narrowed by four query params: `state` (`open` / `waiting` /
`closed` / `all`), `assignee` (`me` / `unassigned` / an agent id), `q` and
`tag` (a tag name; no tag means the inbox, which hides spam — see
[tags.md](tags.md)).

A URL with **no filter params at all** does not mean "everything" — it means
"my inbox", and redirects to the view you last had (stored per session in
`session[:ticket_filters]`), defaulting to `state=open` on a first visit.
Two consequences:

- "all" is an explicit param value, and every filter link in the views names
  its state via `@state_param` — no internal link may generate a bare
  `/tickets` by accident.
- A URL with *some* params but no `state` (an old bookmark, the header search
  submitted from a ticket screen) keeps the remembered state rather than
  widening to everything.

## Search

```ruby
Message.search("printer fire")   # relation, relevance-ordered, capped at 200
```

FTS5 over `subject` and `body_excerpt`. Punctuation is sanitised, so
`ada@example.com` and `can't` are safe to pass straight through. A blank or
punctuation-only query returns `none`, not everything.

## Auth helpers

```ruby
authenticated?
current_agent           # never nil in practice: open mode supplies a stand-in
current_user_email
current_user_name
current_user_provider
```

See [auth.md](auth.md). In development with no OIDC configured, everything is
served and `current_agent` is a stand-in — you can build the UI without an IdP.

## Pagination

Pagy is in the Gemfile for the ticket list. Not yet wired into
`ApplicationController`.

## Things that do not exist yet

Outbound sending (milestone 5) — composing works against `Message` with
`direction: "outbound"`, but nothing delivers it. Real-time updates are out of
scope for v1; the thread is a normal page load.
