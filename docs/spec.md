# Spool — Build Specification

A small, self-hosted email helpdesk. Support mail arrives, becomes a ticket,
an agent replies, the thread continues. Designed for a team of 1–5.

Named for `/var/spool/mail`, and for the thing you wind thread onto.

---

## Stack

- Latest Rails, latest Ruby (match the `.ruby-version` used in `splat`)
- SQLite — WAL, single primary file, reader/writer connection split
- Tuber for the job queue (beanstalkd-compatible, single Rust binary)
- Solid Cache + Solid Cable (their own SQLite files, Rails 8 default)
- Tailwind CSS + Hotwire. No SPA, no build step beyond Tailwind's watcher.
- Kamal to a single VPS

Deliberately absent: Postgres, Redis, Sidekiq, ActiveStorage, Devise.

---

## Database configuration

### Reader / writer against one file

Both roles point at the *same* `.sqlite3` file. This is not replication — WAL
mode means a committed write is immediately visible to any new reader
connection, so cutover delay is genuinely zero. The benefit is pool isolation:
a slow read can't queue behind a write.

```yaml
# config/database.yml (production)
production:
  primary:
    <<: *default
    database: storage/production.sqlite3
    pool: 1                      # SQLite serialises writes; more is theatre
    timeout: 10000
  primary_replica:
    <<: *default
    database: storage/production.sqlite3
    replica: true
    pool: 5
  cache:
    <<: *default
    database: storage/production_cache.sqlite3
    migrations_paths: db/cache_migrate
  cable:
    <<: *default
    database: storage/production_cable.sqlite3
    migrations_paths: db/cable_migrate
```

```ruby
# config/application.rb
config.active_record.database_selector = { delay: 0.seconds }
config.active_record.database_resolver =
  ActiveRecord::Middleware::DatabaseSelector::Resolver
config.active_record.database_resolver_context =
  ActiveRecord::Middleware::DatabaseSelector::Resolver::Session
```

```ruby
# app/models/application_record.rb
connects_to database: { writing: :primary, reading: :primary_replica }
```

Background jobs run outside the middleware, so wrap anything that writes in
`ApplicationRecord.connected_to(role: :writing)` explicitly rather than relying
on the request-scoped resolver.

### Pragmas

```yaml
default: &default
  adapter: sqlite3
  pragmas:
    journal_mode: WAL
    synchronous: NORMAL
    foreign_keys: true
    busy_timeout: 10000
    cache_size: -64000
    mmap_size: 134217728
```

### Backup

Litestream, one `dbs:` entry for the primary. Cache and cable are regenerable
and need no backup. Because there is no ActiveStorage and no `storage/`
directory of loose blobs, **the primary file is the entire application state** —
that property is the point of the compression design below, and should not be
traded away casually.

---

## Schema

```ruby
create_table :agents do |t|
  t.string :oidc_sub, null: false, index: { unique: true }
  t.string :email,    null: false, index: { unique: true }
  t.string :name
  t.timestamps
end

create_table :customers do |t|
  t.string :email, null: false, index: { unique: true }
  t.string :name
  t.text   :notes
  t.timestamps
end

create_table :tickets do |t|
  t.references :customer, null: false, foreign_key: true
  t.references :assignee, foreign_key: { to_table: :agents }
  t.string   :subject
  t.string   :state, null: false, default: "open"   # open | pending | closed
  t.datetime :last_activity_at, index: true
  t.timestamps
end
add_index :tickets, [:state, :last_activity_at]

create_table :messages do |t|
  t.references :ticket, null: false, foreign_key: true
  t.references :agent,  foreign_key: true            # null for inbound
  t.string  :direction, null: false                  # inbound | outbound | note
  t.string  :message_id, null: false, index: { unique: true }
  t.string  :in_reply_to, index: true
  t.text    :references_header
  t.string  :from_email
  t.string  :from_name
  t.string  :subject
  t.datetime :sent_at, index: true
  t.binary  :headers_blob                            # zstd, :headers dict
  t.binary  :body_blob                               # zstd, :body dict
  t.text    :body_excerpt                            # uncompressed, quote-stripped
  t.integer :headers_dictionary_id
  t.integer :body_dictionary_id
  t.integer :raw_size
  t.timestamps
end

create_table :attachments do |t|
  t.string  :sha256, null: false, index: { unique: true }
  t.string  :content_type
  t.integer :byte_size
  t.binary  :data                                    # plain zstd, no dictionary
  t.timestamps
end

create_table :message_attachments do |t|
  t.references :message, null: false, foreign_key: true
  t.references :attachment, null: false, foreign_key: true
  t.string :filename
  t.string :content_id                               # for inline/cid: images
end

create_table :dictionaries do |t|
  t.string  :kind, null: false                       # headers | body
  t.integer :version, null: false
  t.binary  :data, null: false
  t.integer :sample_count
  t.timestamps
end
add_index :dictionaries, [:kind, :version], unique: true

create_table :templates do |t|
  t.string :name, null: false
  t.string :subject
  t.text   :body
  t.timestamps
end
```

FTS5 external-content table over `messages.body_excerpt` and `messages.subject`,
kept in sync by triggers.

### Notes on the shape

- **No raw MIME column.** Messages are stored split. Byte-identical
  reassembly is abandoned deliberately — reconstructing exact MIME from parsed
  parts is unwinnable, and Fastmail retains a copy if forensics are ever needed.
- **`body_excerpt` is uncompressed** because it is read on every page render
  and indexed by FTS5. Compressing the hot path to save kilobytes is backwards.
- **Attachments are content-addressed by `sha256`.** Corporate email signatures
  attach the same logo to every message; dedup by hash is a far larger win than
  compression on exactly the content that compresses worst. Reference-count
  before deleting a blob.

---

## Compression layer

Use `zstd-ruby`. Wrap it in a custom ActiveRecord type so the rest of the
application never sees it:

```ruby
attribute :body_blob, ZstdText.new(kind: :body)
```

The type handles: compress on write, decompress on read, resolve the dictionary
by the row's `*_dictionary_id`, and fall back to plain zstd when the id is nil.

**Ship with plain zstd (nil dictionary).** Train custom dictionaries once the
corpus reaches roughly 1,000 messages, as a Tuber maintenance job. Two separate
dictionaries:

- `:headers` — short, near-identical across every message (Received chains,
  DKIM, MIME scaffolding). Saturates fast; 1,000 samples is generous.
- `:body` — far more varied. May want 5,000 samples before it beats plain zstd
  by enough to bother. **Measure before adopting**: compare `SUM(raw_size)`
  against `SUM(length(body_blob))` on the existing corpus, with and without.

Training must exclude attachment bytes — already-compressed binary in base64
will only dilute the dictionary.

Dictionaries live in the `dictionaries` table, i.e. inside the same file as the
rows they compress, so any restored backup is self-describing. Never mutate a
dictionary in place; write a new version and leave old rows pointing at the old
one.

**Why the body dictionary earns its keep despite long bodies:** every reply in a
thread quotes the entire prior thread verbatim, so message five contains
messages one through four. Zstd's window collapses repetition *within* a record
but not *across* records — cross-record redundancy is exactly what a
corpus-trained dictionary captures. Do not "optimise" this by storing only the
stripped reply; customers top-post inside quoted text and you will need the
original.

---

## Inbound — IMAP (v1)

Fastmail, app password scoped to IMAP only. Server-side rule files support mail
into a dedicated folder.

A recurring Tuber job polls that folder with `net-imap` (stdlib), fetches raw
RFC822, and enqueues each message for processing. Move processed messages to
`Spool/Done` — **track UIDs and move explicitly; never rely on the `\Seen` flag**,
because anyone opening the mailbox in a client will silently consume the queue.

The poller's only job is to hand raw RFC822 to the ingest job. Keep that
boundary clean: swapping to a Mailgun webhook later must be a config change, not
a refactor. (ActionMailbox's Mailgun ingress is built in; the mailbox class is
unchanged either way.)

### Ingest job — must be idempotent

Both retry paths (IMAP re-poll, provider redelivery) can deliver the same
message twice. Rely on the unique index on `messages.message_id`, rescue the
constraint violation, return.

Order of work:

1. Reject before creating anything: `Auto-Submitted`, `Precedence: bulk`,
   `X-Auto-Response-Suppress`, bounces, and any message Spool itself sent
   (match on outbound `Message-ID`). Mail loops are the classic failure here.
2. Find or create customer by From address.
3. Thread: match `In-Reply-To`, then any id in `References`, against existing
   `messages.message_id`. Fall back to a `[#123]` subject tag. Otherwise open a
   new ticket.
4. Split MIME: header block → `headers_blob`; text/plain and text/html parts →
   `body_blob`; binary parts → `attachments`, deduped by sha256.
5. Strip quoted history with `email_reply_parser` → `body_excerpt`.
6. Inbound message sets ticket state to `open` and touches `last_activity_at`.

---

## Outbound — Mailgun

Configure on a subdomain, `mg.yourdomain.com`, so SPF and MX for the apex stay
with Fastmail untouched. Mailgun DKIM-signs and owns the envelope sender; the
`From:` header remains `support@yourdomain.com` so replies land back in Fastmail
and are picked up by the poller.

Set `Message-ID`, `In-Reply-To` and `References` correctly on every send —
threading in the customer's client and re-threading on their reply both depend
on it. Persist the outbound message with the same split/compress treatment as
inbound. Sending flips the ticket to `pending`.

---

## Auth

OIDC only, via `omniauth_openid_connect`. No password column, no registration,
no reset flow — its absence is a feature, don't add one later by accident.

Config by environment variable, following Splat's pattern:
`OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_DISCOVERY_URL`,
`OIDC_PROVIDER_NAME`, plus `SPOOL_ALLOWED_USERS` / `SPOOL_ALLOWED_DOMAINS`.

An empty allowlist locks everyone out — fail loudly at boot if OIDC is
configured and neither allowlist variable is set.

No roles. At 1–5 people everyone is an agent and everyone sees everything.
Customers never authenticate; there is no portal.

**Open question for the operator:** the IdP is not yet chosen. Google works if
the team is on Workspace; otherwise Pocket ID (passkey-only, single binary) or
Kanidm.

---

## UI

Four screens, Hotwire, no client-side framework.

1. **Ticket list** — filter by state and assignee, default "open, everything",
   sorted by `last_activity_at`.
2. **Ticket detail** — message thread, compose box, template picker, state and
   assignee controls.
3. **Customer detail** — their tickets plus a free-text notes field.
4. **Templates** — plain CRUD, flat list, no categories.

Templates interpolate `{{customer.name}}` and `{{agent.name}}` into the compose
box for the agent to edit. Never auto-send.

**Internal notes** share the message thread with `direction: "note"` —
visually distinct, never emailed. Cheap to build, wanted on day one.

---

## Explicitly out of scope for v1

SLAs. Reporting and dashboards. Tags and labels. Custom fields. Knowledge base.
Multiple inboxes. Ticket merging. Assignment rules. Web forms. Real-time
updates. Customer portal. Search beyond FTS5 over subject and excerpt.

Ticket states are `open`, `pending`, `closed`. Three is enough. Resist `on_hold`.

---

## Suggested milestones

1. Schema, reader/writer database config, zstd type with nil dictionary.
2. Ingest job driven entirely by fixture `.eml` files through the
   ActionMailbox conductor at `/rails/conductor/action_mailbox/inbound_emails`.
   Get threading, MIME splitting and loop rejection correct here — **no live
   mailbox in the loop while iterating.**
3. IMAP poller.
4. UI and OIDC.
5. Outbound via Mailgun.
6. Dictionary training job, once real mail has accumulated.

Target is roughly 1,500 lines of application code. The email plumbing is 80% of
the difficulty and 20% of the code; budget accordingly.
