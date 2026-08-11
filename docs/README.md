# Spool documentation

A small, self-hosted email helpdesk. Support mail arrives, becomes a ticket, an
agent replies, the thread continues. Built for a team of 1–5.

Named for `/var/spool/mail`, and for the thing you wind thread onto.

These documents are the design record. They explain *why* the code is shaped the
way it is — the code itself explains what it does. If you change a decision
recorded here, change the document in the same commit.

## Index

| Document | Covers |
| --- | --- |
| [architecture.md](architecture.md) | Stack, storage model, database configuration, what's deliberately absent |
| [ingest.md](ingest.md) | Inbound mail: rejection, threading, MIME splitting, idempotency |
| [compression.md](compression.md) | zstd layer, dictionaries, when and how to train them |
| [queue.md](queue.md) | Tuber, consumers, the scheduler, the Active Job adapter |
| [auth.md](auth.md) | OIDC, the allowlist, the three configuration states |
| [ui-contract.md](ui-contract.md) | The model API the views are built against |
| [ui.md](ui.md) | The screens: design tokens, screen anatomy, Stimulus and Turbo conventions |
| [todo.md](todo.md) | What's built, what's next, open decisions |

## Orientation for someone (or something) new to the codebase

Read [architecture.md](architecture.md) first — it explains the one constraint
everything else follows from: **the primary SQLite file is the entire
application state.** There is no Active Storage, no blob directory, no second
datastore. That property is why attachments live in a table, why there is a
compression layer at all, and why Action Mailbox was rejected.

Then read [ingest.md](ingest.md). The email plumbing is roughly 80% of the
difficulty and 20% of the code.

## Running it

```bash
bin/setup           # bundle, prepare databases
bin/dev             # web + worker + scheduler + tailwind + tuber (Procfile.dev)
bin/rails test      # the suite
bin/rails test:system
bin/standardrb      # style; --fix to autocorrect
bin/ci              # everything CI runs
```

Style is [Standard](https://github.com/standardrb/standard), matching splat.
There is no house style to learn and no `.rubocop.yml` to argue with — run
`bin/standardrb --fix` and move on. The two per-file exemptions in
`.standard.yml` carry their reasoning inline.

Tuber is expected on `localhost:11300`; override with `TUBER_URL`. Without a
provider configured, Spool runs open in development and every request acts as a
stand-in agent — see [auth.md](auth.md).
