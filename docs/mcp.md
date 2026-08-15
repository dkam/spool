# MCP server

Spool's domain exposed as typed tools over the [Model Context
Protocol](https://modelcontextprotocol.io), so an agent — Claude Code, or
anything else speaking MCP — can read and work tickets without scraping the
UI. Built on the official `mcp` gem.

## Running it

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

Two vocabulary rules, both enforced in `SpoolMcp` so the tools can't drift
from the UI:

- States are the UI's words — `open` / `waiting` / `closed` — never the
  column's `pending`. The translation borrows
  `TicketsController::STATE_FILTERS`, the same single copy the views use.
- Agents are named by email. A named agent must already exist: the server
  provisions nobody but its own stand-in, so a typo is an error, not a new
  colleague.

## Attribution

Writes need an author. Tools that write take an optional `agent_email`; when
it is omitted, the write is attributed to a stand-in agent (`mcp@localhost`,
provisioned on first use, `oidc_sub: "mcp"`) — the same pattern as open mode's
development agent, and for the same reason: `message.agent` must mean
something, and a note signed "MCP" is honest about where it came from.

## Writing outside the request cycle

`bin/mcp` runs outside the DatabaseSelector middleware, so the tools wrap
their writes in `ApplicationRecord.writing`, exactly as jobs do. Reads need no
wrap.

## Adding a tool

A class in `app/mcp/spool_mcp/`, inheriting `MCP::Tool`, registered in
`SpoolMcp.server`. Return `SpoolMcp.ok(payload)` for success and
`SpoolMcp.error(message)` for expected failures — an exception that escapes
`call` becomes an opaque protocol error, so rescue what the caller can act on
(`ActiveRecord::RecordNotFound`, `SpoolMcp::ToolError`, validation failures)
and say what went wrong.

Note the transport validates arguments against `input_schema` before `call`
runs, but a direct `SomeTool.call` in a test bypasses that — which is why the
tools keep their own guards, and why the tests exercise them.
