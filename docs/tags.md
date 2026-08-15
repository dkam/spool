# Tags and spam

Tickets carry tags — `tags` and `ticket_tags`, joined the boring way. Tags
describe the conversation, so they live on the ticket: a message's meaning
belongs to its thread, and a customer wants a flag (below), not a label.

Tags are orthogonal to state on purpose. Spam-ness is not a fourth state: a
ticket that turns out to be a real customer goes back into the inbox without
losing where it was in open/pending/closed.

Names are normalised to lowercase (`Tag.named!`), so "Spam" and "spam" are one
chip, not two. The unique index on `ticket_tags (ticket_id, tag_id)` is what
lets `Ticket.tagged` join without a DISTINCT — at most one row per ticket per
name — which matters because it has to compose with `with_read_state_for`'s
select list. `not_tagged` is a NOT EXISTS for the same reason `unread_for` is:
a ticket with *other* tags must still count, and the join must not multiply
rows. A tag change touches the ticket row, because the row is the Turbo
broadcast signal and a tag change moves the ticket between list views.

## Spam is a tag with behaviour

`Ticket#mark_spam!` does two things in one transaction: tags the ticket `spam`
and stamps `customers.blocked_at`. `#unmark_spam!` takes both back. The pairing
lives in the model so no caller — the ticket page's button, MCP's
`update_ticket` — can apply half of it.

**A blocked sender's mail is still ingested.** `Ingest::Inbound` stores it like
any other message and then tags the ticket; nothing is dropped. Rejection
(LoopGuard) is for mail that is *mechanically* not correspondence — bounces,
auto-replies — where storing nothing is correct. A block is a human judgment
about a sender, made once, in the past, and sometimes wrong; the worst case has
to be "sat in the spam view until someone looked", never "vanished without
trace".

State stays open on a spam-tagged arrival, again on purpose: untag it and the
ticket is back in the inbox exactly as it would have arrived.

## The inbox hides spam

Every list view — the UI's and `list_tickets` over MCP — excludes spam-tagged
tickets unless the spam tag is the active filter, "all" states included. Same
deal every mail client offers: spam is a place you go, not a narrowing of what
you were looking at. The header counts skip them too; a badge nagging about
tickets the list refuses to show reads as a bug.

The tag chips on the list toggle — clicking the active one returns to the
inbox — so the group never has to name its default state. The group renders
only once a tag exists.

## What is deliberately absent

- **No tag CRUD screens.** Tags are created on first use and outlive their last
  use; the filter row only offers names that exist.
- **No classifier.** The signals are there when wanted — Fastmail's
  `X-Spam-Score` sits in every stored header blob, "subject says Re: but
  threading found no ancestor" falls out of `Threader`, and the zstd dictionary
  layer could support compression-distance classification once there is a
  corpus. Today, blocking is manual and the automation is only "the next one
  from a blocked sender files itself".
- **No per-message tags, no customer tags.** A customer gets one bit,
  `blocked_at`, and it means exactly one thing.
