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
      │                             the transport, stamps delivered_at
      ▼
Outbound::Smtp | Outbound::Mailgun  SMTP (Mail::SMTP) or Mailgun (POST /v3/<domain>/messages.mime)
```

The row is the source of truth. `compose!` stores everything a send needs —
the Spool-issued `Message-ID`, `In-Reply-To`/`References` built from
`ticket.last_emailed_message`, subject, body — and the queue carries a pointer
and nothing else. Delivery reads the row and adds no content of its own.

## Transports

Two transports, one seam (`deliver_mime(to:, mime:)` → a string for the log
line). SMTP wins when `SMTP_ADDRESS` is set — the common case for a local
relay or an inbox provider with SMTP creds (Fastmail, Gmail) — with Mailgun
as the fallback for the subdomain/DKIM setup. Both share `SPOOL_MAILBOX` as
the `From:` header, so the customer's reply lands back in the folder the
poller reads regardless of transport.

### SMTP (`Outbound::Smtp`)

Uses the `mail` gem's `Mail::SMTP` directly — not ActionMailer, so the
outbound path pulls in no mailer framework, just the MIME library Rails
already depends on. The settings surface is the same one ActionMailer's
`smtp_settings` understands, hence the env var names (`SMTP_ADDRESS` etc.).

TLS is on by default and secure: STARTTLS auto on 587, implicit TLS on 465,
certificate verification on (the mail gem leaves `verify_mode` unset, which
Net::SMTP treats as `VERIFY_PEER`). `SMTP_OPENSSL_VERIFY_MODE=none` is the
one escape hatch — for a local relay with a self-signed cert — and a boot
warning surfaces it so it can't drift into a production deploy unnoticed.

Net::SMTP errors split into two buckets, matching the Mailgun path's
divide: permanent failures (auth, 5xx, refused recipient, unsupported
command) raise `Outbound::Rejected` so the consumer buries rather than
cycling; transient trouble (421, ECONNREFUSED, timeouts) propagates for
retry, then bury via `MAX_RETRIES`.

### Mailgun (`Outbound::Mailgun`)

Sends go to the `messages.mime` endpoint with a fully-built RFC822 message,
not the parameter endpoint. The parameter endpoint has Mailgun assemble the
message — including generating its own `Message-ID` — which would break both
threading in the customer's client and `LoopGuard`'s recognition of our own
mail echoed back. The ids Spool stored are the ids that go over the wire.

Mailgun is configured on a **subdomain** (`mg.yourdomain.com`) so SPF and MX
for the apex stay with Fastmail untouched. Mailgun DKIM-signs and owns the
envelope sender; the `From:` header stays `SPOOL_MAILBOX`. Reach for this
when you want a provider handling deliverability (DKIM, bounce handling,
suppression lists) rather than sending through your inbox provider.

JMAP submission was considered and rejected: submitting through Fastmail
requires `Email/set` first, i.e. a token with account-wide mail *write*
access, and "Spool never writes to the mailbox" is an invariant worth more
than one fewer vendor (see the token discussion in `.env.example`).

## Configuration

Env-only, the JMAP poller's pattern — optional, and one switch per
transport: with neither set, nothing enqueues, nothing sends. SMTP takes
precedence when `SMTP_ADDRESS` is present.

| Variable | Transport | Meaning |
| --- | --- | --- |
| `SPOOL_MAILBOX` | both | The `From:` header. Required for either transport. |
| `SMTP_ADDRESS` | SMTP | The relay host. Setting this (with `SPOOL_MAILBOX`) configures SMTP. |
| `SMTP_PORT` | SMTP | Default 587 (STARTTLS auto); 465 turns implicit TLS on. |
| `SMTP_USER_NAME` / `SMTP_PASSWORD` | SMTP | Omit both for no-auth (an open local relay). |
| `SMTP_AUTHENTICATION` | SMTP | Default `plain`. |
| `SMTP_DOMAIN` | SMTP | HELO/EHLO domain. |
| `SMTP_ENABLE_STARTTLS_AUTO` | SMTP | Default true. `false` for a plaintext-only relay. |
| `SMTP_ENABLE_TLS` | SMTP | Force implicit TLS on a non-465 port. |
| `SMTP_OPENSSL_VERIFY_MODE` | SMTP | Default verified (`peer`). `none` disables — warn at boot. |
| `MAILGUN_API_KEY` | Mailgun | A *sending* API key, scoped to the domain. |
| `MAILGUN_DOMAIN` | Mailgun | The verified sending subdomain. |
| `MAILGUN_API_BASE` | Mailgun | Only for Mailgun's EU region. |

Unconfigured (development, a fresh checkout), composing works exactly as
before: the row is stored, correctly threaded, and shown in the thread as
"Queued · not yet delivered". Nothing pretends to have sent.

## delivered_at

`messages.delivered_at` is stamped when the transport accepts the message, and is
what makes delivery idempotent: a job redelivered after its TTR, or a backfill
racing a live send, finds the stamp and skips. The stamp is written *after*
the transport accepts, so the crash window is "accepted but not stamped" — a
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
  email), or a `Rejected` from the transport (Mailgun bad key / unknown
  domain / refused recipient; SMTP auth failure / 5xx / refused recipient).
  The same request would fail the same way; burying makes it visible in
  tuber's stats instead of cycling.
- **Retry, then bury after `MAX_RETRIES`** — network trouble, 5xx, rate
  limiting (429 is deliberately not `Rejected`), SMTP 421 / transient 4xx,
  connection failures, missing configuration.

## Backfill

```console
$ bin/rails outbound:backfill
```

Queues every outbound message with `delivered_at IS NULL` — replies composed
before a transport was configured (including everything from before delivery
existed), or while the queue was down. Safe to run at any time: the
per-message `idp` key suppresses anything already on the tube, and
`delivered_at` skips anything already sent. It refuses to run unconfigured
rather than queueing jobs that can only bury themselves.

## Testing

`Outbound::Delivery` is driven directly with a fake transport, `Outbound::Smtp`
with a stubbed `Mail::SMTP`, and `Outbound::Mailgun` with a fake HTTP — no
queue, no network, no HTTP stubbing library, the same arrangement as the Jmap
tests. The consumer stays thin enough not to need tests of its own, like
`InboundConsumer`.
