# Architecture

## Stack

- Rails 8.1, Ruby 4.0.6 (matching `splat`)
- SQLite — WAL, single primary file, reader/writer connection split
- [Tuber](https://github.com/tuberq/tuber-rs) for the job queue (beanstalkd-compatible, single Rust binary)
- Solid Cache + Solid Cable, each in its own SQLite file
- Tailwind CSS + Hotwire. No SPA, no build step beyond Tailwind's watcher
- Kamal to a single VPS

Deliberately absent: Postgres, Redis, Sidekiq, Solid Queue, Active Storage,
Action Mailbox, Action Text, Devise.

## The one constraint

**The primary SQLite file is the entire application state.** Not "most of it" —
all of it. Messages, attachment bytes, compression dictionaries, sessions.

This is what makes the backup story a single Litestream `dbs:` entry, and a
restore a single file copy that is immediately self-describing (the
dictionaries needed to decompress the rows live in the same file as the rows).

Everything below follows from it, and it should not be traded away casually.

### Why there is no Active Storage

`ActionMailbox::InboundEmail` stores raw MIME through `has_one_attached
:raw_email`, so adopting Action Mailbox means adopting Active Storage, which
means application state outside the primary file — either loose blobs in
`storage/` or a second service to back up.

The conductor UI at `/rails/conductor/action_mailbox/inbound_emails` is a real
convenience and we gave it up on purpose. What replaces it:
`Ingest::Inbound.ingest(raw)` takes bytes, so `test/services/ingest/inbound_test.rb`
drives the entire pipeline straight from `.eml` fixtures with no mailbox, no
queue and no HTTP in the loop. That is a better development story than the
conductor, not a worse one.

The cost is real and worth naming: Action Mailbox's built-in Mailgun/Postmark
ingress routes are gone. Re-implementing one is a controller that verifies the
provider's signature and calls `Ingest::Inbound.ingest` — see
[ingest.md](ingest.md#swapping-the-transport).

`require "rails/all"` is therefore replaced by selective railtie requires in
`config/application.rb`.

## Database configuration

### Reader/writer against one file

`primary` and `primary_replica` in `config/database.yml` point at the **same**
`.sqlite3` file. This is not replication. WAL mode means a committed write is
immediately visible to any new reader connection, so the cutover delay is
genuinely zero and `delay: 0.seconds` on the database selector is correct rather
than optimistic.

The benefit is pool isolation: a slow read can't queue behind a write.

```ruby
# app/models/application_record.rb
connects_to database: { writing: :primary, reading: :primary_replica }
```

Test is the exception — it points `reading` at `:primary`, because the suite
runs inside an uncommitted transaction on the writer connection and a genuinely
separate reader connection would see an empty database.

### Writer pool size

The build spec called for `pool: 1` on the writer, reasoning that SQLite
serialises writes so anything more is theatre. That reasoning is right about
*throughput* and wrong about *checkout*: the Active Record pool governs
connection checkout, not writing, and a thread holds its connection for a whole
unit of work rather than for the instant it writes.

With a writer pool smaller than the thread count, "wait briefly for the write
lock" — which `busy_timeout: 10000` already handles — becomes
`ActiveRecord::ConnectionTimeoutError` after 5 seconds, which loses the job.
This was not theoretical; it was caught the first time a worker ran three
consumers against `pool: 1`.

So the writer pool is `RAILS_MAX_THREADS` (default 5): one connection per
thread, and SQLite does the serialising it was always going to do.

### Background jobs and the writing role

Jobs run outside `ActiveRecord::Middleware::DatabaseSelector`, so they default
to the reading role and any write raises `ActiveRecord::ReadOnlyError`.

`Ingest::TubeConsumer#process_one_batch` wraps every batch in
`Rails.application.executor.wrap { ApplicationRecord.writing { ... } }`. Both
halves matter: `writing` picks the right role, and `executor.wrap` returns the
connection to the pool at the end of each batch — without it, a consumer thread
holds its connection for the life of the process.

Anything else writing off the request path should use `ApplicationRecord.writing`.

### Pragmas

WAL with `synchronous: normal` is the high-throughput SQLite configuration:
readers never block writers, and there's one fsync per checkpoint rather than
one per commit. `cache_size: -64000` is negative to mean KB rather than pages.

### Backup

Litestream, one `dbs:` entry for `storage/production.sqlite3`. Cache and cable
are regenerable and need no backup.

## Schema

```
agents           oidc_sub (unique), email (unique), name
customers        email (unique), name, notes
tickets          customer, assignee → agents, subject, state, last_activity_at
messages         ticket, agent, direction, message_id (unique), in_reply_to,
                 references_header, from_email, from_name, subject, sent_at,
                 headers_blob, body_blob, body_excerpt,
                 headers_dictionary_id, body_dictionary_id, raw_size
attachments      sha256 (unique), content_type, byte_size, data
message_attachments  message, attachment, filename, content_id
ticket_reads     agent, ticket, last_read_at        (unique on agent+ticket)
dictionaries     kind, version, data, sample_count   (unique on kind+version)
templates        name, subject, body
oidc_sessions    oidc_sid (unique), session_id, user_email, expires_at
```

Plus `messages_fts`, an FTS5 external-content table over `messages.subject` and
`messages.body_excerpt`, kept in sync by triggers.

### Notes on the shape

- **No raw MIME column.** Messages are stored split. Byte-identical reassembly
  is abandoned deliberately — reconstructing exact MIME from parsed parts is
  unwinnable (boundary strings, transfer-encoding choices and header folding all
  vary), and the upstream mailbox retains a copy if forensics are ever needed.

- **`body_excerpt` is uncompressed**, because it is read on every page render
  and indexed by FTS5. Compressing the hot path to save kilobytes is backwards.

- **Attachments are content-addressed by `sha256`.** Corporate signatures attach
  the same logo to every message; dedup by hash is a far larger win than
  compression on exactly the content that compresses worst. Reference-count
  through `message_attachments` before deleting a blob
  (`Attachment#destroy_if_orphaned!`).

- **Ticket states are `open`, `pending`, `closed`.** Three is enough. Resist
  `on_hold`.

- **Read state is per agent** (`ticket_reads`), not a boolean on tickets. With
  more than one agent, "read" is a fact about a person. A ticket is unread when
  there's no row or when `last_read_at` predates `last_activity_at`, so a
  customer reply makes a read thread unread again.

### FTS5 lives outside the schema dump

Virtual tables and triggers cannot be represented in the `:ruby` schema, so
`db:schema:load` would silently ship a deploy where search returns nothing.
Worse, Active Record 8.1's SQLite dumper crashes on an external-content FTS5
table (its `arguments` come back `nil`, then `nil.split`), truncating
`db/schema.rb` mid-write on every `db:migrate`.

So: `config/initializers/messages_fts.rb` excludes them from the dump, and
`Search::Fts.ensure!` creates them idempotently at boot — and again in
`test_helper.rb`, because `rails/test_help` reloads the schema after the
initializer has run.

`Search::Fts.rebuild_if_empty` reads `messages_fts_docsize` rather than
`messages_fts` to decide whether the index is populated. Querying an
external-content FTS table reads the *content* table, so `SELECT count(*) FROM
messages_fts` returns the messages count whether or not anything is indexed.
Asking `messages_fts` whether it is indexed is measuring the wrong table.

### One external-content index serves exactly one table

`messages_fts` is declared `content='messages', content_rowid='id'`, which means
it stores no text at all — only the inverted index, mapping token to rowid,
where **the rowid _is_ `messages.id`**. Column values are read back out of
`messages` on demand.

That has a consequence worth stating before someone tries: **customers cannot go
in this index.** The rowid space is already `messages.id`, so customer 5 and
message 5 are the same document. There is physically nowhere to put a second
entity.

The escape is to drop external content and add discriminator columns
(`kind`, `gid`, `text`), but then FTS5 stores its own copy of everything
indexed — a second, uncompressed copy of every `body_excerpt` inside the file.
That fights the constraint this whole document is built on. Don't.

So a second searchable entity means either a second FTS table or a different
mechanism. For **customers, the answer is `LIKE`, not FTS**, and the reason is
capability rather than cost: FTS5 matches whole tokens and prefixes only, so
`field` cannot reach `fieldworks.co` and `dana` cannot reach
`sales+dana@corp.com` without the trigram tokeniser. `LIKE '%…%'` gets infix
matching for free. It is a full scan, which at a few thousand customers is
sub-millisecond and at 100k would not be — that is the point where a real
`customers_fts` earns its keep, and by then it would want trigram anyway.

Two smaller properties of the index that surprise people:

- **`body_excerpt` is quote-stripped**, so the index covers the reply and not
  the history quoted beneath it. Searching a phrase a customer quoted back at
  you finds nothing. That is deliberate — otherwise every message in a thread
  matches every phrase in it — but it does not announce itself.
- **`Search::Fts.sanitize` preserves a trailing `*`**, so prefix queries already
  work. `milne` matching "Dan Milne" needs nothing special; that is plain token
  matching, not partial matching.

## The four screens

1. **Ticket list** — filter by state and assignee, default "open, everything",
   sorted by `last_activity_at`.
2. **Ticket detail** — message thread, compose box, template picker, state and
   assignee controls.
3. **Customer detail** — their tickets plus a free-text notes field.
4. **Templates** — plain CRUD, flat list, no categories.

Internal notes share the message thread with `direction: "note"` — visually
distinct, never emailed. See [ui-contract.md](ui-contract.md).

## Explicitly out of scope for v1

SLAs. Reporting and dashboards. Tags and labels. Custom fields. Knowledge base.
Multiple inboxes. Ticket merging. Assignment rules. Web forms. Real-time
updates. Customer portal. Search beyond FTS5 over subject and excerpt.
