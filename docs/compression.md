# Compression

Message headers and bodies are stored zstd-compressed. Attachments are stored
zstd-compressed and deduplicated by content hash.

## The layer

```
Message#body  ──►  CompressedColumn  ──►  Compression::Codec  ──►  zstd
                          │                       │
                    body_blob                DictStore (cached dictionaries)
                    body_dictionary_id
```

- `Compression::Codec.encode/decode(text, dict_id:)` — the only place that
  touches zstd for text. `dict_id: nil` means plain zstd.
- `Compression::DictStore` — per-process cache of dictionaries, by id (for
  decode) and by kind (for encode). Dictionaries are immutable once written, so
  a cached entry can never go stale, only be superseded.
- `CompressedColumn` — the model concern. `compressed_column :body, kind: :body`
  defines `#body` / `#body=` over `body_blob` and `body_dictionary_id`.

Nothing outside these three files knows compression exists.

### Why a concern and not an ActiveRecord::Type

The build spec sketched `attribute :body_blob, ZstdText.new(kind: :body)`. That
shape can't work: an `ActiveRecord::Type` receives only the column value, never
the row, so it cannot read the sibling `body_dictionary_id` to discover which
dictionary the row was written with. Storing the id inside the blob instead
would duplicate the column and let the two disagree.

The encapsulation the spec actually asked for — nothing outside the layer
touching zstd — holds either way.

### The dictionary is resolved at write time

`CompressedColumn` asks `DictStore.current_id(kind)` when the attribute is
assigned, and records the answer in the row. A row therefore names the
dictionary it was *actually* compressed with, and later training can never
invalidate it.

## Dictionaries

Two kinds, trained separately:

- **`headers`** — short and near-identical across every message (Received
  chains, DKIM, MIME scaffolding). Saturates fast; 1,000 samples is generous.
- **`body`** — far more varied. May want 5,000 samples before it beats plain
  zstd by enough to bother.

Stored in the `dictionaries` table — that is, inside the same file as the rows
they compress, so any restored backup is self-describing.

**Never mutate a dictionary in place.** `Dictionary.promote!` inserts a new
version and leaves existing rows pointing at the old one, which stays readable
forever. "Current" is simply the highest version for the kind, so there is no
`active` flag to fall out of sync.

`DictStore::ACTIVE_TTL` (300s) bounds how long a process keeps writing with a
superseded dictionary — and, more importantly, how long a worker that booted
before any dictionary existed caches the "none" answer. Without the TTL that
answer would stick until restart and every row would stay plain-zstd forever.

## Ship plain, train later

Spool ships with an empty `dictionaries` table. Every row is plain zstd
(`*_dictionary_id` is `NULL`) until there is a corpus worth training against —
roughly 1,000 messages.

This is not a placeholder; it is the correct starting state. A dictionary
trained on 50 messages is worse than none.

### Measure before adopting

```sql
SELECT
  SUM(raw_size)                                        AS raw,
  SUM(LENGTH(headers_blob) + LENGTH(body_blob))        AS stored,
  ROUND(1.0 * SUM(raw_size) /
        SUM(LENGTH(headers_blob) + LENGTH(body_blob)), 2) AS ratio
FROM messages;
```

Run it before and after. If a body dictionary doesn't clear the current ratio by
a meaningful margin, don't promote it.

Observed on a synthetic support-reply corpus (300 samples, 16 KB dictionary):

| | bytes |
| --- | --- |
| raw | 191 |
| plain zstd | 158 |
| with dictionary | **34** |

Short messages are exactly where plain zstd fails — frame overhead can make a
small body *larger* compressed. That's the case a dictionary fixes.

### Why the body dictionary earns its keep despite long bodies

Every reply in a thread quotes the entire prior thread verbatim, so message five
contains messages one through four. Zstd's window collapses repetition *within*
a record but not *across* records — and cross-record redundancy is exactly what
a corpus-trained dictionary captures.

### Training

`zstd-ruby` exposes `Zstd::CDict`/`DDict` for *use* but has no training API, so
training shells out to the `zstd --train` CLI (the same approach splat takes):

```bash
zstd --train samples/*.txt -o body.dict --maxdict=16384
```

Then `Dictionary.promote!(kind: :body, data: File.binread("body.dict"), sample_count: n)`.

**Training must exclude attachment bytes.** Already-compressed binary in base64
will only dilute the dictionary — and attachments don't use one anyway.

This is milestone 6 and is not built yet. See [todo.md](todo.md).

## Attachments

`Attachment.store!(bytes, content_type:)` hashes with SHA-256, returns the
existing row if the hash is known, otherwise compresses with **plain zstd, no
dictionary** and inserts.

No dictionary because attachment bytes are usually already compressed (PNG, PDF,
docx, zip); a dictionary trained on prose would do nothing for them.

The real win here is dedup — the same signature logo arriving on every message
from a given sender. `test/services/ingest/inbound_test.rb` covers the case
where two different senders attach identical bytes under different filenames:
one `attachments` row, two `message_attachments` rows.

Reference-count before deleting: `Attachment#destroy_if_orphaned!`.
