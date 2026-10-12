# Queue

[Tuber](https://github.com/tuberq/tuber-rs) — a beanstalkd-compatible job queue
in a single Rust binary. Expected on `localhost:11300`; override with
`TUBER_URL`.

Solid Queue is deliberately not used. Spool already runs tuber alongside splat,
and keeping one queue technology across both is worth more than Solid Queue's
zero-extra-process property. The Ruby client is the
[`tuber` gem](https://github.com/tuberq/tuber-gem) — a rename of the beaneater
fork this used to track, adding `reserve_batch` and the `con:`/`idp:` put
options on top of beaneater 1.1.4.

Don't resolve `tuber` to `0.0.1` — that version is a name reservation containing
nothing but a `VERSION` constant. The constraint is `~> 0.7`, the first release
with recurring schedules; the server needs to be tuber 0.16 or later for the
same reason.

### `Tuber` means two things

`Ingest::Tuber` is Spool's wrapper; `::Tuber` is the gem. Inside `module Ingest`
a bare `Tuber` resolves to the wrapper, so **every reference to the gem is
written `::Tuber`**.

Getting this wrong is not a loud failure. `rescue Tuber::NotFoundError` inside
`Ingest` looks fine, loads fine, and passes every test that doesn't kill a
connection — because Ruby resolves a rescue class only when something is
actually raised. It fails with `NameError: uninitialized constant
Ingest::Tuber::NotFoundError`, from the error path, in production.

## Tubes

| Tube | Producer | Consumer |
| --- | --- | --- |
| `spool.inbound` | `Jmap::Poller` | `Ingest::InboundConsumer` |
| `spool.outbound` | `Message.compose!` / `outbound:backfill` | `Ingest::OutboundConsumer` |
| `spool.activejob` | `ActiveJob::QueueAdapters::TuberAdapter` | `Ingest::ActiveJobConsumer` |
| `spool.maintenance` | tuber's own schedule (`config/schedule.yml`) | `Ingest::DispatchConsumer` |

Inbound and outbound are separate so a provider outage backing up sends can't
stall ingestion.

## Processes

```
bin/worker [role]     # role: mail | maintenance | all (default all)
```

There is no scheduler process — see [Recurring jobs](#recurring-jobs).

Roles are defined in `Ingest::Worker::ROLES`. At Spool's scale one process runs
everything, and `Procfile.dev` starts `all`. The split exists so that in
production a long maintenance job — dictionary training reads and recompresses a
chunk of the corpus — can't sit in front of a customer's email waiting to become
a ticket.

## `Ingest::TubeConsumer`

The base class. Subclasses implement `#process_batch(jobs)`; everything else is
handled here, and each piece is load-bearing:

- **Connect and WATCH on the reserving thread.** Client connections are
  per-thread. A watch issued on another thread wouldn't apply to the socket this
  thread reserves on, and the worker would silently reserve from `default`
  (always empty) and never drain its tube.

- **`executor.wrap` + `ApplicationRecord.writing` around every batch.**
  `writing` is needed because consumers run outside the DatabaseSelector
  middleware and would otherwise write on the reading role and raise
  `ReadOnlyError`. `executor.wrap` returns database connections to the pool at
  the end of each batch — without it a consumer thread holds its connection for
  the life of the process, and the other consumers in an `all` worker never get
  one. (This was a real failure, not a hypothetical: the symptom was
  `ConnectionTimeoutError` after 5s on the very first job.)

- **Touch heartbeat (`keeping_alive`).** A job's TTR is the server's "is this
  worker still alive?" timer. Hold a job past its TTR without touching and tuber
  hands it to someone else while this worker is still on it. The heartbeat
  shares the consumer's connection deliberately — a reservation belongs to the
  connection that made it, so a touch from any other socket is `NOT_FOUND`. It
  is `join`ed rather than killed: killing mid-touch would abandon a half-written
  command on the shared socket and desync the protocol for every later reserve.

- **Reconnect on connection loss.** Tuber restarting under a worker is normal.
  The worker rebuilds the connection (which re-WATCHes) and carries on; in-flight
  jobs are re-reserved after their TTR. On boot it waits for tuber indefinitely
  rather than crashing — a worker with no live queue has nothing to do but wait.

- **Give up after `MAX_RETRIES` — and never bury.** A poison-pill message
  would otherwise cycle forever, so after five retries the consumer reports the
  job to Sentry and deletes it. A failure no retry will change (a body that
  won't parse, a send the transport refused) is given up on straight away.

  Deleting rather than burying is deliberate. A buried job is visible only to
  someone who asks tuber, and it keeps its `idp:` key live — see `idp:` below
  for the six weeks that cost. Nothing is lost by deleting, because every job
  here points at something that outlives it, and each consumer records what to
  recover in a place the header reads (see `MailHealth`):

  | Consumer | Given up on, the thing survives as | Recovered by |
  | --- | --- | --- |
  | `InboundConsumer` | the mail in the mailbox, plus a `DroppedMail` row (`kind: "failed"`) with its Message-ID and receivedAt | `bin/rails jmap:rewind` |
  | `OutboundConsumer` | the reply, a `Message` with no `delivered_at` | `bin/rails outbound:backfill` |
  | `DispatchConsumer` | the schedule, which runs it again next tick | nothing — it doesn't retry either |
  | `ActiveJobConsumer` | nothing; report only | — |

## Active Job

`config.active_job.queue_adapter = :tuber` resolves to
`ActiveJob::QueueAdapters::TuberAdapter` in `lib/active_job/queue_adapters/`,
which sits at exactly the path Zeitwerk expects for that constant (this is why
`config.autoload_lib` must not ignore `active_job`).

Job queue *names* ride in the payload rather than mapping onto separate tubes.
Spool's Active Job volume is a handful of jobs a day, and one tube with one
consumer is easier to reason about. The latency-sensitive work — inbound mail —
doesn't go through Active Job at all; it has its own tube and consumer.

## Recurring jobs

`config/schedule.yml` is the whole set, and tuber runs it. Every worker, at
boot, syncs the file to tuber under the owner `spool` (`Ingest::Schedule`), and
tuber puts each entry's `{class:, args:}` body onto its tube when it falls due.
A fire is an ordinary put. `Ingest::DispatchConsumer` drains
`spool.maintenance` and calls `#perform` on the named class. These are plain
classes, not Active Job subclasses — there's no serialisation contract to
negotiate.

A sync replaces the owner's entire set: an entry deleted from the file is
deleted from tuber, an edited one is updated in place, and an identical sync
changes nothing — so two workers booting together is harmless. It happens at
boot and never on reconnect. During a rolling deploy an old worker re-syncing
after a tuber blip would put back entries the new release removed.

The sync runs on a thread of its own and waits for tuber as long as it takes,
the way the consumers do. A schedule tuber *refuses* — a typo'd zone, an unknown
key in the file, a tuber older than 0.16 — is logged and sent to Sentry, not
retried. It would only be refused again, and tuber keeps running the schedule it
already had.

Tuber keeps the schedule in its binlog, so it survives tuber's own restarts
without waiting for a worker. A tick missed while tuber was down fires once
for the gap by default (`catchup:`).

Each entry takes exactly one of `every:` (epoch-aligned, with optional
`offset:`) or `cron:` (UTC unless `zone:` names one), plus:

- **`idp:`** — tuber idempotency key. Until the job holding that key is
  *deleted*, further fires with it are suppressed — whether the job is ready,
  reserved, delayed or **buried**. Use on anything that can run longer than its
  own interval; it's what stops a slow JMAP poll from stacking a second poller
  behind the first. The buried case is the trap: a buried `jmap_poll` held its
  key for six weeks, every put the old scheduler logged as "firing" was absorbed
  by the dead job, and inbound mail stopped. That is why `DispatchConsumer`
  deletes failed jobs rather than burying them. Tuber now counts those absorbed
  fires per entry as `buried_streak` in its schedule stats.
- **`con:`** — tuber concurrency key. Caps simultaneous reserves across all
  consumers for jobs sharing the key.
- **`catchup:`** — `once` (default), `never`, or a number of seconds.

To see what tuber holds:

```ruby
c = Ingest::Tuber.producer
c.schedules.list("spool")
c.schedules.stats("spool", "jmap_poll")   # next_fire, last_result, buried_streak, ...
```

## Health

`Ingest::Tuber.reachable?` distinguishes "up with an empty queue" from
"unreachable" — `queue_depth` reports both as `0`, which makes a down queue look
healthy. `queue_depths` gives the per-tube breakdown, fetched live because
tuber's stats are in memory.
