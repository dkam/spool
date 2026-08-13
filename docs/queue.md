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
nothing but a `VERSION` constant, and the constraint is `~> 0.5` to keep the
floor above it.

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
| `spool.outbound` | compose action (milestone 5) | not built yet |
| `spool.activejob` | `ActiveJob::QueueAdapters::TuberAdapter` | `Ingest::ActiveJobConsumer` |
| `spool.maintenance` | `bin/scheduler` | `Ingest::DispatchConsumer` |

Inbound and outbound are separate so a provider outage backing up sends can't
stall ingestion.

## Processes

```
bin/worker [role]     # role: mail | maintenance | all (default all)
bin/scheduler         # reads config/schedule.yml, puts jobs on their tubes
```

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

- **Bury after `MAX_RETRIES`.** A poison-pill message would otherwise cycle
  forever. A buried job is visible in tuber's stats and can be kicked back once
  the bug is fixed, which is the point — silently dropping a customer's email is
  worse than leaving it buried.

`Ingest::InboundConsumer` additionally buries immediately on a malformed job
body: a body that won't parse will never parse, so five retries buy nothing.

## Active Job

`config.active_job.queue_adapter = :tuber` resolves to
`ActiveJob::QueueAdapters::TuberAdapter` in `lib/active_job/queue_adapters/`,
which sits at exactly the path Zeitwerk expects for that constant (this is why
`config.autoload_lib` must not ignore `active_job`).

Job queue *names* ride in the payload rather than mapping onto separate tubes.
Spool's Active Job volume is a handful of jobs a day, and one tube with one
consumer is easier to reason about. The latency-sensitive work — inbound mail —
doesn't go through Active Job at all; it has its own tube and consumer.

## Scheduler

`config/schedule.yml`, read by `bin/scheduler`, which uses rufus-scheduler to
put `{class:, args:}` bodies onto a tube. `Ingest::DispatchConsumer` drains
`spool.maintenance` and calls `#perform` on the named class. These are plain
classes, not Active Job subclasses — there's no serialisation contract to
negotiate.

Per-entry options:

- **`idp:`** — tuber idempotency key. While a job with that key is in the tube
  (ready or reserved), further puts with it are suppressed. Use on anything that
  can run longer than its own interval; it's what stops a slow JMAP poll from
  stacking a second poller behind the first.
- **`con:`** — tuber concurrency key. Caps simultaneous reserves across all
  consumers for jobs sharing the key.

One scheduler process, and if it dies no recurring jobs fire until it restarts.
That's the trade for not putting a scheduler table in SQLite, and nothing Spool
schedules is safety-critical — the worst case for a missed poll is that mail
arrives a minute late.

A failed put is logged and swallowed: a scheduler that dies on one bad enqueue
stops firing everything else.

## Health

`Ingest::Tuber.reachable?` distinguishes "up with an empty queue" from
"unreachable" — `queue_depth` reports both as `0`, which makes a down queue look
healthy. `queue_depths` gives the per-tube breakdown, fetched live because
tuber's stats are in memory.
