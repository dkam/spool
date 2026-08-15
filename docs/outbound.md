# Outbound

How a reply leaves Spool. The inbound counterpart is [ingest.md](ingest.md).

```
Message.compose!                    the row: Message-ID, threading headers,
      │                             body envelope, state → pending
      ▼
Outbound::Delivery.enqueue          { message_id: } onto spool.outbound,
      │                             idp: outbound-<id>
      ▼
Ingest::OutboundConsumer            drains the tube
      │
      ▼
Outbound::Delivery.deliver!         builds the MIME from the row, hands it to
      │                             Mailgun, stamps delivered_at
      ▼
Outbound::Mailgun ── Outbound::Http POST /v3/<domain>/messages.mime
```

The row is the source of truth. `compose!` stores everything a send needs —
the Spool-issued `Message-ID`, `In-Reply-To`/`References` built from
`ticket.last_emailed_message`, subject, body — and the queue carries a pointer
and nothing else. Delivery reads the row and adds no content of its own.

## Why Mailgun, and why the `.mime` endpoint

Mailgun is configured on a **subdomain** (`mg.yourdomain.com`) so SPF and MX
for the apex stay with Fastmail untouched. Mailgun DKIM-signs and owns the
envelope sender; the `From:` header stays `SPOOL_MAILBOX`, which is what makes
the customer's reply land back in the Fastmail folder the poller reads.

Sends go to the `messages.mime` endpoint with a fully-built RFC822 message,
not the parameter endpoint. The parameter endpoint has Mailgun assemble the
message — including generating its own `Message-ID` — which would break both
threading in the customer's client and `LoopGuard`'s recognition of our own
mail echoed back. The ids Spool stored are the ids that go over the wire.

JMAP submission was considered and rejected: submitting through Fastmail
requires `Email/set` first, i.e. a token with account-wide mail *write*
access, and "Spool never writes to the mailbox" is an invariant worth more
than one fewer vendor (see the token discussion in `.env.example`).

## Configuration

Env-only, the JMAP poller's pattern — optional, and one switch:

| Variable | Meaning |
| --- | --- |
| `MAILGUN_API_KEY` | A *sending* API key, scoped to the domain. Unset ⇒ nothing enqueues, nothing sends. |
| `MAILGUN_DOMAIN` | The verified sending subdomain. |
| `MAILGUN_API_BASE` | Only for Mailgun's EU region. |
| `SPOOL_MAILBOX` | Already set — it becomes the `From:` header. |

Unconfigured (development, a fresh checkout), composing works exactly as
before: the row is stored, correctly threaded, and shown in the thread as
"Queued · not yet delivered". Nothing pretends to have sent.

## delivered_at

`messages.delivered_at` is stamped when Mailgun accepts the message, and is
what makes delivery idempotent: a job redelivered after its TTR, or a backfill
racing a live send, finds the stamp and skips. The stamp is written *after*
the provider accepts, so the crash window is "accepted but not stamped" — a
possible duplicate email, never a silently lost one. That is the right side to
err on.

It is also the honesty bit: the thread header and `get_ticket` over MCP show
an outbound message as sent only once this is set.

## Failure handling

The enqueue in `compose!` is best-effort: the reply is already committed, and
raising over a down queue invites the real failure — an agent re-sending a
duplicate. Failures are logged and sent to Sentry, and the backfill sweeps up.

In the consumer (`Ingest::OutboundConsumer`):

- **Bury immediately** — a job body that won't parse, a Message row that
  doesn't exist, a message that can never be sent (a note, a customer with no
  email), or a `Rejected` from Mailgun (bad key, unknown domain, refused
  recipient). The same request would fail the same way; burying makes it
  visible in tuber's stats instead of cycling.
- **Retry, then bury after `MAX_RETRIES`** — network trouble, 5xx, rate
  limiting (429 is deliberately not `Rejected`), missing configuration.

## Backfill

```console
$ bin/rails outbound:backfill
```

Queues every outbound message with `delivered_at IS NULL` — replies composed
before Mailgun was configured (including everything from before delivery
existed), or while the queue was down. Safe to run at any time: the
per-message `idp` key suppresses anything already on the tube, and
`delivered_at` skips anything already sent. It refuses to run unconfigured
rather than queueing jobs that can only bury themselves.

## Testing

`Outbound::Delivery` is driven directly with a fake Mailgun client, and
`Outbound::Mailgun` with a fake transport — no queue, no network, no HTTP
stubbing library, the same arrangement as the Jmap tests. The consumer stays
thin enough not to need tests of its own, like `InboundConsumer`.
