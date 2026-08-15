# Todo

Status as of the initial build. Milestones follow the build specification.

## Done

### Milestone 1 — foundation
- [x] Rails 8.1 / Ruby 4.0.6 skeleton, Active Storage and Action Mailbox removed
- [x] Reader/writer `database.yml` against one file, WAL pragmas
- [x] Full schema and migrations
- [x] zstd layer: `Compression::Codec`, `DictStore`, `CompressedColumn`
- [x] FTS5 external-content table + triggers, ensured at boot
- [x] Tuber queue plumbing, consumers, scheduler, Active Job adapter

### Milestone 2 — ingest
- [x] `Ingest::Inbound.ingest(raw)` — the single entry point
- [x] Loop and auto-reply rejection (`LoopGuard`)
- [x] Threading: `In-Reply-To` → `References` → `[#id]` subject tag (`Threader`)
- [x] MIME splitting, charset transcoding (`MimeSplitter`)
- [x] Attachment dedup by sha256
- [x] Quote stripping to `body_excerpt`
- [x] Idempotency, including synthetic `Message-ID` for mail that lacks one
- [x] 22 tests driven from `.eml` fixtures

### Out of sequence (done early)
- [x] OIDC auth ported from splat (milestone 4's auth half)
- [x] Per-agent ticket read state (`ticket_reads`)

## Next

### Milestone 3 — JMAP poller
- [x] `Jmap::Client` — session, batched calls, blob download; no gem
- [x] `Jmap::Poller` — read the folder, put raw RFC822 on `spool.inbound`
- [x] ~~Move processed messages to `Spool/Done`~~ — **Spool never writes to the
      mailbox.** The move was the only thing needing write access, and a JMAP
      token is scoped to an account rather than a folder, so it would have meant
      a credential able to rewrite every folder on the account. Also **nothing
      reads or writes the `\Seen` flag**, so nothing done in a mail client can
      consume the queue.
- [x] `Jmap::PollJob` + the `jmap_poll` entry in `config/schedule.yml`
- [x] Decide where the watermark lives — `ingest_cursors`, one row per folder:
      a `receivedAt` plus the ids sharing that second, because JMAP's `after`
      filter is inclusive and `receivedAt` is second-granular.
- [ ] Point it at a real mailbox and watch it run

Built against JMAP rather than IMAP: Fastmail wrote the protocol, `Email/query`
scopes cleanly to one folder, and the whole poll is one HTTP request plus the
blob downloads. It needs an **API token**, not an app password — see
`.env.example`. Neither published Ruby JMAP gem is maintained, and none is
needed: JMAP is JSON over HTTPS.

The poller's only job is to hand raw bytes to `Ingest::Inbound.ingest`. Keep
that boundary clean.

The token must be **read-only**. The poller logs a warning every poll if given
one that can write.

Push is available and works — the session advertises `eventSourceUrl`, and
`EmailDelivery` is the type to watch (`Email` advances on every flag change
anywhere in the account). Deliberately not used yet: it carries state rather than
payloads, a long-lived SSE connection can die silently, so a periodic sweep is
the floor regardless — and with the cursor in place an idle poll is one API call
returning nothing. Push would buy latency and nothing else.

### Milestone 4 — UI
- [x] Ticket list (filters in a turbo-frame, read state via `with_read_state_for`)
- [x] Ticket detail (thread, composer on `Message.compose!`, assign/close)
- [x] Customer detail (stat grid, ticket list, autosaving notes)
- [x] Unread indicators using `ticket_reads`
- [x] Attachment download (`send_data`, filename from the join) + `cid:` rewriting
- [x] Login screen restyled
- [ ] Templates CRUD — the model and `#render` exist; no screen yet
- [ ] Wire Pagy into `ApplicationController` — the ticket list is unpaginated

See [ui.md](ui.md) for the screens and [ui-contract.md](ui-contract.md) for the
model API.

### Milestone 5 — outbound via Mailgun
- [x] Mailgun on a subdomain (`mg.yourdomain.com`), so SPF and MX for the apex
      stay with Fastmail untouched — see [outbound.md](outbound.md)
- [x] `From:` stays `support@yourdomain.com` so replies land back in Fastmail
      and the poller picks them up
- [x] Set `Message-ID`, `In-Reply-To` and `References` correctly on every send —
      the stored row goes over the wire verbatim via Mailgun's `.mime` endpoint,
      so the provider can't substitute its own ids
- [x] Persist the outbound message with the same split/compress treatment
      (was already true: delivery reads the row `compose!` stores)
- [x] Sending flips the ticket to `pending` (`record_outbound_activity!`)
- [x] `spool.outbound` tube + consumer, `delivered_at` stamp for idempotency
- [ ] Set up the Mailgun account/subdomain and set `MAILGUN_API_KEY` /
      `MAILGUN_DOMAIN`, then `bin/rails outbound:backfill` to send the
      replies stored before delivery existed

### Milestone 6 — dictionary training
- [ ] `Compression::DictTrainingJob` — shell out to `zstd --train`
- [ ] Train `headers` at ~1,000 messages; `body` may want ~5,000
- [ ] Exclude attachment bytes from the training corpus
- [ ] **Measure before promoting** — see [compression.md](compression.md)
- [ ] Schedule as a maintenance job

### Phase 3/4 — MCP
- [ ] Expose Spool over MCP using the `mcp` gem (~> 1.1), following splat's
      `app/mcp/splat_mcp_server.rb`
- [ ] Decide the tool surface: search tickets, read a thread, draft a reply
- [ ] Auth: splat uses per-user `McpToken` renewed by web activity — copy that
      shape rather than inventing one
- [ ] Explicitly deferred until the UI exists

### Later
- [ ] AI-assisted reply drafting. Deliberately not now.

## Designed but not built

Two controls exist in the design and were deliberately not shipped, because the
schema doesn't back them and a dead control is worse than an absent one. Both
are cheap to add once the backing exists — see [ui.md](ui.md).

- **Snooze.** Needs `tickets.snoozed_until` plus a decision about what a snoozed
  ticket *is*: a fourth state would break "three is enough", so more likely a
  nullable timestamp that the default filter excludes while it's in the future,
  with inbound mail clearing it (the same reopening logic as
  `record_inbound_activity!`). The list header has a slot waiting.

- **Attachments on outbound mail.** Needs an upload path (which doesn't
  exist — attachments are currently inbound-only) and for `compose!` /
  `Outbound::Delivery.mime_for` to learn multipart bodies. Delivery itself now
  exists, so this is unblocked.

## Open decisions

- **IdP not finally chosen.** Developed against [clinch](../../clinch); works
  with any compliant provider. Google works if the team is on Workspace;
  otherwise Pocket ID (passkey-only, single binary) or Kanidm.
- **Litestream** is not configured yet. One `dbs:` entry for
  `storage/production.sqlite3`; cache and cable are regenerable.
- **Nothing has been deployed yet.** `config/deploy.yml` now describes the real
  thing — three roles, the storage volume, tuber with persistence on, the OIDC
  environment — but every host and hostname in it is a placeholder and no first
  deploy has been run against a server. The Mailgun secrets
  (`MAILGUN_API_KEY`, `MAILGUN_DOMAIN`) are named in it but the Mailgun
  account and subdomain DNS have not been set up.

## Deviations from the build specification

Recorded so nobody has to re-derive them.

1. **No Action Mailbox / Active Storage.** The spec's milestone 2 suggested
   driving ingest through the Action Mailbox conductor, but
   `ActionMailbox::InboundEmail` stores raw MIME as an Active Storage blob,
   which contradicts "the primary file is the entire application state".
   Ingest is driven from `.eml` fixtures instead. See
   [architecture.md](architecture.md#why-there-is-no-active-storage).

2. **`CompressedColumn` concern instead of `attribute :body_blob, ZstdText.new`.**
   An `ActiveRecord::Type` can't see the row, so it can't resolve the sibling
   `*_dictionary_id`. See [compression.md](compression.md).

3. **Writer pool is `RAILS_MAX_THREADS`, not 1.** `pool: 1` turns "wait for the
   SQLite write lock" into `ConnectionTimeoutError`. See
   [architecture.md](architecture.md#writer-pool-size).

4. **`body_blob` holds a JSON document**, so both the text/plain and text/html
   renderings survive. See [ingest.md](ingest.md).

5. **Empty allowlist and production-open are fatal at boot**, not warnings. The
   spec asked to "fail loudly"; splat only warns. See [auth.md](auth.md).

6. **Ticket read state** (`ticket_reads`) is not in the spec's schema. Added
   because unread indicators are what make a shared inbox usable.

## Traps already paid for

Recorded because each one cost real time and none is obvious from the code.

- **`ApplicationRecord.writing`, never `Model.connected_to(role: :writing)`.**
  `prevent_writes` is per connection class; the middleware sets it on
  `ActiveRecord::Base`, so clearing it anywhere else clears a flag nothing
  reads. Pinned by `test/models/writing_role_test.rb`.

- **An unwrapped write on a GET only fails in test.** In development and
  production the roles are separate pools, so it succeeds against the replica
  connection and ships. This is why the selector stays enabled in test.

- **`Search::Fts` must not use `ApplicationRecord.connection`.** A bare
  `.connection` at boot leases the connection to the booting thread and never
  returns it, starving every consumer thread that starts after it.

- **Brace lambdas can't take a bare `rescue`.** `-> { … rescue … }` is a syntax
  error that only surfaces when the file is first loaded — which, for
  `bin/scheduler`, is in production.

- **A link inside a turbo-frame stays inside it.** The ticket rows render in the
  `ticket_list` frame, so they need `data-turbo-frame="_top"` to reach the
  thread; without it Turbo finds no matching frame in `tickets/show` and
  replaces the row with "Content missing". This shipped because every system
  test reached the thread with `visit ticket_path` — **if a screen is reachable
  by clicking, one test has to click it.**

- **`Tuber` inside `module Ingest` is Spool's wrapper, not the gem.** Write
  `::Tuber` for the gem, always. A bare `rescue Tuber::NotFoundError` resolves to
  `Ingest::Tuber::NotFoundError`, and Ruby only evaluates a rescue class when
  something raises — so it passes every test that never kills a connection and
  raises `NameError` from the error path in production. See
  [queue.md](queue.md).

- **zstd stores incompressible input as a raw literal block.** A short body is
  legible inside its own frame. Compression is not obfuscation; don't assert on
  the absence of plaintext.
