# UI

How the screens are built. For the model API the views sit on — accessors,
scopes, the traps — see [ui-contract.md](ui-contract.md); this page is the visual
system and the conventions, and deliberately doesn't restate them.

## Where the design came from

The screens are an implementation of a Claude Design project, `Spool.dc.html`:

    https://claude.ai/design/p/97f11acd-7161-45bc-8310-8aca52766bac

It covers three of the four screens in [architecture.md](architecture.md) — the
ticket list, the ticket thread and the customer page. Templates CRUD is not in
the design and is not built.

The design canvas loads a design system called Modernist alongside the component,
but the component **overrides it**: everything visible comes from a scoped
`.spool` block of CSS variables in `Spool.dc.html`, not from Modernist's
`styles.css`. Those variables are what was ported. Modernist's written direction
still applies and is worth reading for intent — flat, architectural, zero corner
radius, alignment and dividers doing the organising, the accent used sparingly.

The project's other two files are scaffolding, not design: `support.js` is the
canvas's React runtime, and `_ds_bundle.js` is empty (Modernist is pure CSS).
Neither has an equivalent here and neither needs one.

## Tokens

`app/assets/tailwind/application.css` is the whole design system. The `.spool`
variables became Tailwind v4 `@theme` tokens, so every utility resolves through
them:

| Token | Utility | Role |
| --- | --- | --- |
| `--color-canvas` | `bg-canvas` | the page ground |
| `--color-ink` | `text-ink` | primary text |
| `--color-soft` | `text-soft` | supporting text |
| `--color-faint` | `text-faint` | labels, metadata, placeholders |
| `--color-rule` | `border-rule` | the ordinary divider |
| `--color-rule-strong` | `border-rule-strong` | the heavier divider that opens a section |
| `--color-hover` | `hover:bg-hover` | row wash |
| `--color-accent` | `bg-accent` | unread, and the dot on a primary action |

Roles, not hues — nothing in a template names a colour.

Two exceptions, both because the file cannot reach the stylesheet:

- **The favicon** — `public/icon.svg`, its rendered `icon.png` and
  `manifest.json.erb`'s `theme_color` all write `#f0592a` literally, because
  none of them can read a CSS variable. If the accent ever changes, those three
  change by hand; the re-render command is in a comment in the SVG.
- **`errors/auth_misconfigured.html.erb`** — renders with `layout: false` and a
  `<style>` block of literal greys, and also carries the app's only
  `border-radius`. Its job is to report a missing variable at boot, so it has to
  render when the layout or the compiled stylesheet is exactly what's broken.
  **Do not "fix" it to use tokens** — depending on the asset pipeline is the one
  thing this page must not do. It deliberately doesn't look like Spool.

**Dark theme is one block.** Tailwind v4 compiles utilities to `var(--color-*)`
references rather than baked-in hex, so redeclaring the same variables under
`[data-theme="dark"]` re-themes the entire app. There is no `dark:` variant
anywhere in the codebase and there should not be one: if a colour needs a dark
counterpart, it belongs in that block, not on the element.

Type scale is also tokenised — `text-2xs` (11px uppercase labels) through
`text-title` (21px screen headings), with `text-base` at 15px rather than
Tailwind's 16px. `leading-message` is the looser line height message bodies are
set at; interface text uses the default 1.55.

### Rules of the system

- **No rounded corners.** The only `rounded-full` in the app is the dots, and
  the only `border-radius` is in the boot-failure page above, which is outside
  the system on purpose.
- **No shadows and no filled surfaces.** Structure comes from alignment and
  dividers. If something needs separating, it gets a rule.
- **Flush left**, including labels inside wide controls.
- **The accent is for state**, not decoration: the unread dot, the dot on the
  send button. Links are ink and underline on hover.
- Focus is a 2px accent `:focus-visible` ring, set once in the base layer.

## The screens

```
app/views/
  layouts/application.html.erb   <html data-theme>, fonts, pre-paint theme script
  shared/_header.html.erb        the 58px bar
  tickets/
    index.html.erb               list: heading, counts, filters, rail
    _filters.html.erb            state + assignee chips
    _ticket_row.html.erb         one row — shared with the customer screen
    show.html.erb                thread: breadcrumb, header, rail, composer
    _message.html.erb            one thread entry, three treatments
    _composer.html.erb           reply/note box + template picker
  customers/show.html.erb        stat grid, ticket list, autosaving notes
  settings/show.html.erb         the agent's MCP token: issue once, rotate, revoke
  login/index.html.erb           the signed-out screen
  shared/_footer.html.erb        version, revision, Rails, Ruby, GitHub
```

**The footer answers "what exactly am I looking at?"** — asked most often of an
instance somebody else deployed, which is why it is on every screen including
the login page. It carries **two** numbers, because they answer different
questions (see [deploy.md](deploy.md)): `Spool::VERSION` is the release you can
say out loud, `config.x.revision` is the commit actually running, and a version
alone cannot tell you whether the deploy you just did took. Both link to GitHub
— a bare hex string with no way to look it up is half a fact — and an
`unknown` revision is omitted rather than printed, because the word looks like
a value.

`Spool::SOURCE_URL` in `config/version.rb` is where the links come from. It is
written a second time, literally, in the Dockerfile's
`org.opencontainers.image.source` label, which cannot read Ruby; those are the
only two copies.

The footer also **makes room for the shortcut legend**, which is fixed to the
same bottom-left corner. Only while the legend is up (`body:has(…)` in the
stylesheet, since the legend renders after the footer and CSS cannot select
backwards) — it stays up until `?` puts it away, and it covers the version
numbers completely.

**The header carries what you can act on.** The nav and the search box render
only when `current_agent` is present, because the login screen renders the same
layout: a Tickets link there returns you to the page you are on, and a search
box answers nothing. The wordmark, the mailbox address and the theme switch stay
— locked out, "which instance is this" is still a real question. The condition
is `current_agent` rather than `authenticated?` on purpose: open mode has no
session, so `authenticated?` is false on a wholly usable app. The same goes for
the Settings link beside Sign out — the stand-in agent has settings too.

**The header says when mail has stopped, and otherwise nothing.** Signed in,
`MailHealth#problems` renders in accent before the mailbox address — "No mail
check for about 2 hours", "1 message failed to arrive", "3 replies not
delivered" — each with its next step as a tooltip. There is no healthy state to
show: a green dot on every page is a thing you stop seeing, and the point is to
be seen the day it matters. It reads only SQLite, never tuber, so a hung queue
can't slow the page that is trying to report it. See [ingest.md](ingest.md#dropped-mail-droppedmail).

**The rail** — the vertical hairline with dots on it — is the one structural
motif shared by all three screens. A container gets `relative pl-[30px]` with an
absolutely positioned 1px line at `left-1`, and each child hangs a `-left-[30px]`
dot on it. Filled accent means unread or new; a hollow ink ring means read; a
dashed ring means an internal note.

**The three message treatments** carry the conversation and are load-bearing, not
decoration: inbound sits flush left, outbound is indented 96px and labelled "Sent
to customer", and a note is indented with a dashed dot, muted ink and "Internal
note · not sent to the customer". The requirement that a note can never be
mistaken for something the customer saw is in ui-contract.md, and the composer
enforces it too — switching to note mode hides the recipient address.

## Design → schema decisions

Most of the design maps onto the schema directly. These are the places it
didn't, and what was done instead.

| Design | Decision |
| --- | --- |
| "Open / Waiting on customer / Closed" | Labels over the stored `open`/`pending`/`closed`. `TicketsHelper::STATE_LABELS` for the long form, `STATE_FILTER_LABELS` for the terse chips. The URL uses `?state=waiting`. |
| Unread dot, bold subject, "N unread" | Real per-agent read state (`ticket_reads`). Lists load through `Ticket.with_read_state_for(agent)` and call `ticket.unread?`; the detail page uses `unread_for?`. |
| Row preview | The newest message's `body_excerpt`, prefixed with the author when it came from our side ("You: …", "Ines: …"). Without that you can't tell whether the last word was the customer's or ours. |
| "Show quoted text" | `body_excerpt` is the reply with history stripped; the remainder of `body_text` is the quoted block. **Text bodies only** — in HTML the quoted history is structural and not reliably separable, so HTML bodies render whole with no disclosure. |
| Customer "Organisation" | The email domain. There is no organisations table, and for business senders the domain is the honest answer. |
| Customer "Local time · GMT+1" | Replaced with "Last heard from". No timezone is stored for a customer, and inventing one would be worse than showing a fact the schema holds. |
| Nav: Tickets / Ticket / Customer | The design's nav switched canvas screens. Ticket and customer are drill-downs here, so the nav carries only Tickets. |
| Ticket header "Assign" | A native select — the design had nowhere to put the list of agents. Styled down to read as the text button beside it; auto-submits. |
| Ticket header "Snooze" | **Not built.** Nothing in the schema backs it, and a control that silently does nothing is worse than an absent one. The header has a slot waiting; what it needs is in [todo.md](todo.md#designed-but-not-built). |
| Composer "Attach" | **Not built.** Outbound attachments need an upload path, and the delivery MIME (`Outbound::Delivery.mime_for`) is text-only — so an attachment could not go anywhere yet. |

Both omissions are the design being ahead of the schema, not oversights, and
both should land when the feature behind them does.

Worth knowing before building Snooze, because it is the part that isn't obvious
from the design: a snoozed ticket cannot simply be hidden. Inbound mail has to
clear the snooze the same way it reopens a closed ticket, or snoozing quietly
becomes a way to lose a customer's reply.

## JavaScript

Stimulus only, one controller per behaviour, no inline handlers.

| Controller | Does |
| --- | --- |
| `theme` | Light/dark, following the system until told otherwise. Sets `data-theme` on `<html>`, marks the active button, and keeps `localStorage["spool:theme"]` only while the choice differs from the system. |
| `disclosure` | The quoted-text show/hide, with the label swap. |
| `composer` | Reply/note toggle, template panel, template insertion at the cursor. |
| `notes` | Debounced customer-notes autosave, flushing on blur and `pagehide`. |
| `autosubmit` | `requestSubmit()` on change — the assignee select. |
| `shortcuts` | Keyboard navigation and the legend. See below. |
| `search` | Debounced search-as-you-type, Escape to clear, and a flush when the box loses focus. See below. |

Two things worth knowing:

**The theme is applied before first paint** by an inline script in the layout
head, not by the controller — Stimulus connects after the page has painted, which
would mean a white flash for dark-theme users on every load. Turbo replaces
`<body>` and leaves `<html>` alone, so the attribute set there survives every
navigation and the script runs once per full load.

**The system's light/dark setting is the default, and there is no "System"
button.** A choice is remembered only while it differs from what the system
says: picking the theme the system would have given you anyway forgets the
choice, and Spool follows the system again, live, when it flips. The two words
stay a plain switch, and the tooltip says which of the two is in charge.

**Templates insert, never send.** `composer#useTemplate` inserts at the cursor
when there's already a draft rather than replacing it.

## The keyboard

**Bare keys, the way Gmail and GitHub do it.** Shift still works, for fingers
that learned it when it was required.

| Key | Does | Where |
| --- | --- | --- |
| `J` / `K` | Next / previous row | any list |
| `L` / `↵` / `→` | Open the selected row | any list |
| `J` / `K` | Next / previous ticket in the list it was opened from | ticket |
| `H` / `Esc` / `←` | Back to that list | ticket |
| `T` | The ticket list, unnarrowed | everywhere |
| `/` | Focus search — on the list, or go there | everywhere |
| `?` | Show / hide the legend | everywhere |
| `↓` / `↑` | Next / previous result | caret in the search box |
| `↵` | Open the selected result, or put the box down | caret in the search box |
| `Esc` | Clear the box, then put it down | caret in the search box |

**What keeps a shortcut out of a reply is the field check.** A key pressed with
the caret in an input, a textarea, a select or anything contenteditable belongs
to the field, never the page. The check reads `event.composedPath()[0]` rather
than `event.target`, which stops at a shadow root's host — so a field inside a
web component still counts as a field.

This was the other way round until 2026-10: every key was gated behind Shift,
Basecamp-style, on the argument that a chord is a safer guard than a list of
elements to exclude, since a control added later can't accidentally opt into
swallowing keystrokes. It didn't earn its cost. The list is short and closed;
the field check was already running for every key and carried `/` on its own;
and the chord cost a modifier on every keystroke on every screen, plus a
double-tap-Shift "latch" mode whose only job was to hand the bare keys back
after a search. If a custom widget that takes typing ever arrives that is none
of those elements, it belongs in `typing()`.

**`↑` and `↓` are not page shortcuts.** On a ticket they are how you read a long
thread, and a key that scrolls one screen and leaves another is worse than a key
with one meaning. `←` and `→` have no competing meaning — nothing here scrolls
sideways — so they take in and out.

**`Esc` means out.** On a ticket that is back to the list; in the search box it
clears, then lets go. It never touches the legend, which `?` puts up and puts
away — otherwise an open legend would swallow the first Escape on every ticket.
In the composer it does nothing: leaving a half-written reply on a keystroke is
not something to do by default.

**Enter on a link or a button is that control's.** Enter opens the selected row
only when focus is on nothing that Enter already activates.

**`T` and `H` are not the same key twice.** H retraces a step — back to the list
this ticket was opened from, filter and all. T ignores history and goes to the
inbox as it is, which is why it is offered on the list itself: a search and two
filters deep, it is the way out of what you have narrowed yourself into. Its
target is the header's nav link, so the key exists exactly where that link does,
and the controller never learns a route.

**`/` works everywhere, not only where the box is.** The box lives on the list;
from a ticket or a customer, `/` goes to the list (the same place T goes) and
puts the caret in the box when it arrives. The legends on those screens offered
`/` for a while after search moved off the header, and pressing it did nothing.
The focus is skipped while Turbo shows a cached preview of the list, whose box
is about to be thrown away.

### The legend

`?` puts a legend up bottom-left saying what the current screen answers to, and
`?` puts it away. It **stays up across screens** in between (`sessionStorage`,
per tab) — you open it to learn the keys, and each screen's are different. It
takes the accent rule and soft text, the same promotion the rail dot gets when
a row is selected: while it is up it is the running state of the page rather
than a passing hint.

A morph refresh would otherwise hide it. The server renders the legend
`hidden` — it has no idea you put it up — and a broadcast refresh morphs the
page toward that HTML. The controller cancels `turbo:before-morph-attribute`
for `hidden` on the legend and its items, so their visibility stays its own.

### Stepping through tickets

**On a ticket, `J` and `K` go to the next and previous ticket in the list it was
opened from** — that list, in its order, with its filter. Triage is reading one
ticket after another, and going back to the list between each of them is two
keys of overhead per ticket.

Opening a row records the tickets on screen alongside the origin (see below).
The list is a snapshot, not a live query, so closing a ticket as you go doesn't
pull the next one out from under you. Stepping moves the origin with you, so H
from wherever you stop goes back to the list you started from, with the cursor
on the ticket you stopped at. People rows are left out: stepping is ticket to
ticket. A ticket opened cold has no list, so its legend doesn't offer J/K — the
`step` target is unhidden only when there are at least two tickets to move
between.

### Reaching the results

**While the caret is in the search box, `↓`/`↑` walk the results and `↵` opens
the highlighted one.** Nothing to put down first — `/`, type, `↓`, `↵` is the
whole path from anywhere to a ticket or a person.

The list is `fieldKeys` in the controller, kept deliberately separate from
`keys`:

- **The letters have to stay letters.** `J`, `K`, `L` and `H` begin Jane, Kevin,
  Lisa and Harry, which is exactly what someone searching People types.
- **The arrows cost nothing.** In a single-line input `↑`/`↓` only jump the caret
  to an end it is usually already at, and walking a result list with them is
  what every search box already does.
- **`↵` with nothing picked, or `Esc` in an empty box, puts the box down**: you
  have asked your question, and the letters go back to being the list's. `Esc`
  with something in the box is the search controller's, and clears it first —
  clearing is not leaving, since you may be about to type a different question.

**Putting the box down asks a pending search at once.** The search controller
flushes its debounce on `focusout`. Left to the timer, the answer would land a
moment after you had started walking the results and reset the cursor — and
Enter used to submit the form *and* leave the timer running, so the same query
went out twice. With nothing pending there is nothing to ask: the results on
screen already answer what is in the box.

The cursor still clears when the frame re-renders, so typing another character
drops the highlight — the results underneath it are different ones.

`shortcuts` is mounted on `<body>` in the layout — one controller for the whole
app — and **each screen declares what it offers by which targets it renders**:

| Target | Rendered by | Gives |
| --- | --- | --- |
| `row` | `tickets/_ticket_row`, `tickets/_person_row` | J / K / L |
| `back` | the ticket breadcrumb | H, and J / K between tickets |
| `search` | the ticket list's search box | `/` focuses it; elsewhere `/` goes to it |
| `tickets` | the header's nav link | T, and where `/` goes |
| `hint` | the layout, from `content_for :shortcuts` | the legend |
| `step` | the ticket's legend | the J / K item, shown only with a list behind it |

**The cursor tracks `data-row-id`, not `data-ticket-id`**, because a search list
holds two kinds of row and a person has no ticket id. Row ids are namespaced —
`ticket-12`, `customer-3` — so J and K walk People and Tickets as one sequence
and L opens whichever is under the cursor. `data-ticket-id` stays on ticket rows
for a different job: pairing a ticket with the list it was opened from, which
only tickets have. A person row deliberately records no origin, because
`customers/show` offers no H for it to answer.

A screen with none of them is inert, and nothing in the controller knows which
screen it is on. Adding shortcuts to a new screen is `content_for :shortcuts`
plus the targets — no registration step.

The trap in that design is that `row` targets arrive with the shared partial,
so a screen can answer to J/K/L without ever having decided to. The customer
screen did exactly that: the keys worked, and nothing on the page said so. **If
a screen renders `tickets/_ticket_row`, it owes the reader a legend.** The
customer screen declares J/K/L and deliberately not H. That was originally a
mechanism argument — the loose origin made H a dead key there — and the pairing
below has since removed it. It stays out on taste: "back" from a customer is
ambiguous between the ticket list and the ticket you followed the customer link
from, and a key that picks one of two plausible meanings is worse than a key
that isn't offered.

**The selection is remembered across the round trip**, in `sessionStorage` under
`spool:selected-ticket`: open a ticket, press `H`, and you land back on the row
you left rather than at the top of the list. `spool:ticket-origin` remembers the
list URL alongside it so the filter you were in survives too, and the tickets
that list showed, which is what J and K step through from a ticket. Both are per-tab
on purpose: two tabs on two tickets shouldn't fight over one cursor.

**The origin is stored paired with the ticket it belongs to** — `{ticket, url,
list}`, not a loose "last list I was on" — and `back()` only uses it when the ticket
matches, otherwise falling through to the breadcrumb's own href. That pairing
is load-bearing in two directions, and a loose string was wrong in both:

- The breadcrumb fallback could never fire. Once anything had been opened, a
  ticket reached cold from a pasted link went "back" to a filtered list it had
  no relationship with.
- On a screen that lists tickets itself, the last list *is* that screen, so `H`
  would visit the page it was already on — a key that looks broken rather than
  one that is absent. That is the mechanism the customer screen's note above
  refers to as superseded: `H` is safe to add there now, and stays out on taste.

Restoring is done in `rowTargetConnected`, not in `connect`, because rows come
and go every time the `ticket_list` frame re-renders.

**A cursor belongs to a list**, so asking a different question starts it at the
top of the answer. The frame being replaced by a new request is the moment that
means exactly that — a filter click and a search both do it — and
`clearSelection()` hangs off `turbo:before-frame-render`. Coming back from a
ticket is a page visit rather than a frame render, so that keeps its place,
which is the memory anyone actually asked for.

*Before*-frame-render, not `turbo:frame-render`: Turbo swaps the new rows in
and then waits a frame or two before announcing it has rendered. Clearing on
the announcement undid a key pressed in between — on rows already on screen,
so you saw the results, pressed `J`, and watched the cursor vanish. A test
presses `J` from a MutationObserver the moment the rows land, which hits that
window every time.

Without it the first `J` after a search lands somewhere that depends on whether
the ticket you were looking at minutes ago happened to survive the narrowing:
usually the top, silently not when it didn't. Searching a *person* is where that
reads worst, because the row it skips is the People section — the thing you
searched for. `clearSelection` strips `data-selected` as well as forgetting the
id, since `rowTargetConnected` has already marked the surviving row by the time
the frame finishes rendering.

**The cursor is drawn on the rail dot the row already has** rather than as a
second mark: an accent core, a ring of canvas, then a hairline of accent
(`a[data-selected] .rail-dot` in the stylesheet). Unread is a filled dot and
read is a hollow one, so a *ringed* dot is the one shape left that neither can
be confused with, and it stays legible sitting on top of either. It is a quiet
mark by design; if it proves too quiet in use, the next step is a row wash, not
a louder dot.

**`rail-dot` is a hook, not decoration.** Any row that can hold the cursor needs
the class on its dot or it selects invisibly — correct in the DOM, unchanged on
screen. The person row shipped without it and every keyboard test still passed,
because they all assert `[data-selected]`, which is the attribute rather than
the paint. `dot_colour` in the system test reads the computed background so at
least one test can tell selected from looks-selected.

## Search

**There is no search screen.** Search is another narrowing of the ticket list —
`?q=` alongside `?state=` and `?assignee=` — so it composes with the filters and
inherits the `ticket_list` frame, `turbo_action: advance`, the keyboard targets
and `_ticket_row` for nothing. A separate screen would need its own copy of all
of that and would drift from the inbox the first time either changed.

That also answers "how do you get back": you don't, because you never left. The
search is a chip in the filter row like any other narrowing, and clearing it is
the same gesture as clearing a state filter. Escape in the box does it too.

**The box lives in the header**, not on the inbox, because the moment search
earns its keep is mid-reply — *what did we tell them last time* — and that
happens on the ticket screen.

### Instant, but in the page

Typing refreshes the `ticket_list` frame on a 220ms debounce; the frame's
`turbo_action: advance` keeps the address bar in step. Results appear as you
type, in the list you already know how to read, and every state you type through
stays linkable and back-able. A dropdown gets none of that.

The frame is also what makes it possible at all: only the frame swaps, so the
header, the box and the caret in it are untouched. **Off the inbox there is no
such frame**, so `ApplicationHelper#search_frame_target` sends the form to `_top`
instead and the controller doesn't type ahead — a full navigation per keystroke
would replace `<body>` and throw the caret away mid-word. Enter still works.

### Two kinds of answer, two sections

| | Matched by | Shown as |
| --- | --- | --- |
| **People** | `Customer.search` — LIKE over name and email | one row per person, capped at 5, linking to `customers/show` |
| **Tickets** | `Search::Fts.ticket_matches` — FTS5 over `messages.subject` and `body_excerpt` | normal ticket rows |

A person match isn't a smaller ticket match, it's a different kind of answer.
Ranking them into one list would mean someone with forty tickets buries every
message that actually contained the word you typed — and the useful answer to a
person's name is the person, once. `customers/show` is already the screen that
lists all their tickets, so the row is a pointer rather than an expansion.

**People deliberately ignore the state and assignee filters.** A person is not
open or waiting.

### The traps, and what each one costs

- **LIKE for customers, FTS for content, and it's capability not cost.** What
  you want from an address is *infix* — `ilne` → `Milne`, `field` →
  `dana@fieldworks.co`. FTS5 only does prefix, so it can't answer either without
  the trigram tokeniser. There is also nowhere to put customers in
  `messages_fts`: it's external-content keyed `content_rowid='id'` on messages,
  so the rowid space is already spoken for. See architecture.md.
- **`% and _` are escaped** in the LIKE pattern, with `ESCAPE '\'` — and so is
  the backslash itself, which is the half that's usually forgotten.
- **The cap counts tickets, not messages.** `ticket_matches` collapses to one
  row per ticket *inside SQLite* with a window function, then limits. Capping
  the FTS query instead — 200 matching messages might be 12 tickets — truncates
  invisibly. `Message.search` still caps at messages, which is right at message
  granularity and wrong at ticket granularity; that's why this doesn't wrap it.
- **A result previews the message that matched**, not the newest one. Otherwise
  a hit for `smtp_tls` shows "Thanks, that worked" and you can't see why it's in
  your results. That's the whole reason the search returns a message id.
- **`where(id: …)`, never `joins(:messages)`.** `with_read_state_for` already
  LEFT JOINs and adds a select; joining messages too multiplies a ticket by its
  matching messages, and the DISTINCT you'd reach for collides with that select.
- **`body_excerpt` is quote-stripped**, so quoted history isn't searchable. That
  is right — otherwise every thread matches every phrase anyone ever quoted into
  it — but it's surprising enough to be worth saying out loud.
- **The filter can silently eat a search.** Searching while a stale `state=`
  filter is on looks identical to no results. The empty state says *"in this
  filter"* and offers a link that drops it, without claiming there's anything
  there.
- **Two characters minimum.** Below that the list stays as it was rather than
  being narrowed by a letter that matches most of the table.

## Turbo

The ticket list's filters and rows share a `turbo_frame_tag "ticket_list"` with
`data-turbo-action="advance"`, so a filter click swaps both the rows and the
chips' own active state, and the address bar keeps up — a filtered inbox stays
linkable and the back button still works.

Everything else is a normal page load. Real-time updates are out of scope for v1;
the thread does not stream.

## Adding a screen

1. Take colours, type and spacing from the tokens. Never write a hex.
2. No shadow, no radius, no filled panel. Reach for a rule.
3. If it lists tickets, load through `with_read_state_for(current_agent)` and
   reuse `tickets/_ticket_row` — it takes a `compact:` local.
4. If it writes on a GET, read ui-contract.md's "Writing from a GET" first.
5. Long labels: `text-2xs uppercase tracking-[0.09em] text-faint` is the label
   style used throughout.
6. If it has anything to navigate, give it `content_for :shortcuts` and the
   `shortcuts` targets — a screen that answers to no keys should be a decision,
   not an omission.

## Tests

- `test/integration/ui_flows_test.rb` — the screens render, the filters filter,
  and the write paths behind each control do what the control claims (reply →
  pending, note → state untouched and no threading headers, empty reply refused,
  assign/close, notes autosave, attachment download).
- `test/system/spool_ui_test.rb` — the parts that only exist once JavaScript
  runs: the theme following the system, a choice persisting across a navigation
  and being forgotten once it matches the system again, the quoted-text
  disclosure, the template picker not sending, the note toggle hiding the
  recipient, a reply appearing in the thread, and the keyboard — walking the
  list, opening, coming back to the same row, stepping ticket to ticket, the
  legend, and every shortcut key typed into the composer or the search box
  *not* navigating.

The keyboard tests press keys rather than visiting the destination. That
distinction is not pedantry: every system test used to reach the thread with
`visit ticket_path`, which is exactly why a broken link out of the list survived
a green suite for as long as it did.

`db/seeds.rb` reproduces the design's content — a thread with an internal note,
quoted history, an attachment, and a believable mix of read and unread. It is
idempotent, keyed on natural keys rather than on the relative timestamps it
generates.
