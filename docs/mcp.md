# MCP server

Spool's domain exposed as typed tools over the [Model Context
Protocol](https://modelcontextprotocol.io), so an agent — Claude Code, or
anything else speaking MCP — can read and work tickets without scraping the
UI. Built on the official `mcp` gem.

## Two ways in

| | Over HTTP | Over stdio |
| --- | --- | --- |
| Where | `POST /mcp` on the running app | `bin/mcp`, a process on the same machine |
| Who | an agent, by their bearer token | whoever has a shell there |
| Writes signed by | the token's agent, always | `agent_email`, or the stand-in |
| For | an assistant working the real inbox | development, against the local database |

Both serve the same tools from the same `SpoolMcp.server`.

## Connecting over HTTP

**Settings → MCP → Generate token.** The token is shown once, alongside the
command that uses it:

```console
$ claude mcp add --transport http --scope user spool https://spool.example.com/mcp \
    --header "Authorization: Bearer spool_…"
```

`--scope user` makes it answer in every directory. Inside this repo the
project's own `spool` (stdio, below) takes precedence over a user-scoped server
of the same name, so pick another name there if you want both.

Any MCP client that can send a header works the same way. claude.ai's custom
connectors want OAuth instead, which this endpoint doesn't offer.

### The token

`McpToken`, one per agent:

- **Only a SHA-256 digest is stored**, so the page can't show the token again —
  lose it and rotate. A token can send mail to customers, and the database is
  the file that gets backed up and replicated; the copy that ends up elsewhere
  should hold nothing presentable. A digest rather than bcrypt because the
  token is ~250 random bits: there is no dictionary to slow down, and the lookup
  has to be an indexed equality. This is the one place it departs from splat,
  whose settings page shows the token again and so stores it as is.
- **Prefixed `spool_`**, so it is recognisable in a config file or a paste, and
  a pattern a secret scanner can be taught.
- **Rotating is issuing again.** `McpToken.issue!` replaces whatever the agent
  had, and the old token is refused from its next call. Revoke deletes it.
- **The allowlist is checked on every call**, not just at issue: taking an
  address off `SPOOL_ALLOWED_USERS` / `SPOOL_ALLOWED_DOMAINS` revokes its
  token with no row to remember to delete. (Splat's.)
- **`last_used_at`** is shown in Settings, written at most every five minutes.

There is no expiry. Splat also expires a token whose owner hasn't signed in to
the web UI for a while; here the allowlist and rotation cover the cases that
matter at 1–5 people, and an expiring token is one that stops working for a
scheduled job on the morning nobody happened to open the app.

The issued token reaches the settings page through the flash, across the
redirect from `POST /settings/mcp_token`. Rendering it from the POST instead
would leave a reload re-submitting — rotating away the token just copied. The
session cookie is encrypted, and the flash is gone after that one request. The
page is `turbo-cache-control: no-cache`, so Back doesn't restore a snapshot
with the token in it.

### The endpoint

`McpController`, which inherits `ActionController::API` rather than
`ApplicationController`: no session, no cookies, no CSRF token. The bearer
token is the only way in, so a signed-in browser can't reach it by accident.

- **Open mode doesn't open it.** With no IdP configured the UI runs as a
  stand-in agent; `/mcp` still wants a token. Open mode is "no IdP yet", not
  "no authentication", and this endpoint emails customers.
- **Half-configured auth refuses it**, with a 503, as the UI does — the
  allowlist check a token relies on is off in that state too.
- **Not the gem's `StreamableHTTPTransport`**, for splat's reason: with no
  server-sent events to send, it would add per-session state and Host/Origin
  allow-lists (a 403 waiting to happen behind the proxy). Its DNS-rebinding
  guard protects servers that take requests without credentials; browsers
  don't attach bearer tokens on their own. `MCP::Server#handle_json` is the
  whole protocol without any of it.
- A notification gets `202` and no body. `GET` (a client asking for an event
  stream) and `DELETE` (ending a session) get `405` with `Allow: POST`, which
  is what the spec says to answer when there is neither.
- A failed token gets `401`, `WWW-Authenticate: Bearer`, and a JSON-RPC error
  naming the settings URL — a client shows that message to its human, so it
  says where tokens come from and nothing about why this one failed.

POSTs are routed to the writing role by the database selector, so tool reads
and writes both go to the primary; the tools' `ApplicationRecord.writing`
wraps are harmless there.

## Running it locally over stdio

`.mcp.json` at the repo root registers the server for Claude Code, which
starts it on demand. There is nothing to boot or keep running.

The server is `bin/mcp`: a stdio transport around a full Rails boot,
development environment by default. Poke it by hand with:

```console
$ echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | bin/mcp
```

JSON-RPC frames own stdout in that process, so `bin/mcp` points logging at
`log/mcp.log` before the transport opens — a stray log line on stdout corrupts
the stream.

## The tools

Defined in `app/mcp/`, registered in `SpoolMcp.server`.

| Tool | What it does |
| --- | --- |
| `list_tickets` | The inbox. Filters: `state`, `assignee` (email or `unassigned`), `q` (FTS5 search), `tag`. Defaults to open, like the UI, and hides spam-tagged tickets like the UI — `tag: "spam"` is the way in. |
| `get_ticket` | One ticket with its full thread, oldest first. |
| `add_note` | An internal note via `Message.compose!`. Never emailed, state untouched. |
| `reply_to_ticket` | An outbound reply via `Message.compose!` — **this emails a real customer** wherever Mailgun is configured. Moves the ticket to waiting; delivery is asynchronous, and the response's `delivery` field says whether the reply was queued or (unconfigured) only stored. |
| `update_ticket` | Manual state moves (closing, mostly), assignment, and tags (`add_tags` / `remove_tags`). Tagging `spam` also blocks the sender; removing it unblocks — see [tags.md](tags.md). |
| `mail_status` | Whether mail is moving: the header's problems, plus the last clean poll and how far it has read, the last message ingested, live queue depths, mail turned away or given up on (`DroppedMail`), and undelivered replies. Where to start on "why isn't this email in Spool?". |

Two vocabulary rules, both enforced in `SpoolMcp` so the tools can't drift
from the UI:

- States are the UI's words — `open` / `waiting` / `closed` — never the
  column's `pending`. The translation borrows
  `TicketsController::STATE_FILTERS`, the same single copy the views use.
- Agents are named by email. A named agent must already exist: the server
  provisions nobody but its own stand-in, so a typo is an error, not a new
  colleague.

## Attribution

Writes need an author, and `SpoolMcp.author` picks it.

**Over HTTP it is the token's agent.** `McpController` builds the server with
that agent in its `server_context`, which the gem passes to every tool call.
`agent_email` may name them (in any case) but naming a colleague is an error
rather than silently ignored, so a caller who meant to sign as someone else
finds out.

**Over stdio there is no agent.** Tools that write take an optional
`agent_email`; when it is omitted, the write is attributed to a stand-in agent
(`mcp@localhost`, provisioned on first use, `oidc_sub: "mcp"`) — the same
pattern as open mode's development agent, and for the same reason:
`message.agent` must mean something, and a note signed "MCP" is honest about
where it came from.

## Writing outside the request cycle

`bin/mcp` runs outside the DatabaseSelector middleware, so the tools wrap
their writes in `ApplicationRecord.writing`, exactly as jobs do. Reads need no
wrap.

## Errors

The gem answers an exception escaping a tool with an opaque "Internal error
calling tool …" — deliberately, so internals don't reach the client — and
hands the exception to `SpoolMcp.report_exception`, which logs it and sends it
to Sentry. Without a reporter it went nowhere. The caller's own mistakes (an
unknown tool, bad params) arrive there too and are dropped: they are answered
to the client already, and are nothing to fix here.

## Adding a tool

A class in `app/mcp/spool_mcp/`, inheriting `MCP::Tool`, registered in
`SpoolMcp.server`. Return `SpoolMcp.ok(payload)` for success and
`SpoolMcp.error(message)` for expected failures — an exception that escapes
`call` becomes an opaque protocol error, so rescue what the caller can act on
(`ActiveRecord::RecordNotFound`, `SpoolMcp::ToolError`, validation failures)
and say what went wrong.

A tool that writes takes `server_context:` and passes it to
`SpoolMcp.author`, or an HTTP caller's writes will be signed by the stand-in.

Note the transport validates arguments against `input_schema` before `call`
runs, but a direct `SomeTool.call` in a test bypasses that — which is why the
tools keep their own guards, and why the tests exercise them.

## Tests

- `test/mcp/spool_mcp_test.rb` — the tools, called directly.
- `test/integration/mcp_endpoint_test.rb` — `/mcp`: who gets in (no token, a
  wrong, revoked or off-allowlist one, open and half-configured auth), the
  protocol's shapes (notification → 202, GET → 405, a parse error), and who a
  write is signed by.
- `test/models/mcp_token_test.rb` — digest-only storage, rotation, the
  allowlist re-check, the throttled `last_used_at`.
- `test/integration/settings_test.rb` — issuing shows the token once, and
  rotate and revoke do what they say.
