# 04 — Paged prefix query on the File Index

**What to build:** A service should be able to ask the File Index for everything
it knows under a given `(providerId, path)` prefix, a page at a time, without
that service reaching into the indexer's storage. There is no such query today —
the only listing available anywhere is per-directory, one directory at a time.

The index already carries a unique compound index on `(providerId, path)`, so
this is a bounded range scan rather than a collection scan, and it must be
implemented as one. Expose it over NATS request/reply following the conventions
the indexer's existing search request already uses.

**Blocked by:** None — can start immediately.

**Status:** resolved

- [x] A request for a `(providerId, path)` prefix returns the indexed files beneath it, paged, with a cursor to continue from
- [x] Ordering is stable across pages, so a client paging through a large folder sees every entry exactly once
- [x] Prefix matching respects directory boundaries — a folder named `/Photos2` must not match the `/Photos` prefix
- [x] Each entry carries at least path, size, modification time, mime type and whether it is a directory
- [x] An empty or unknown prefix returns an empty page rather than an error
- [x] The query plan is a range scan over the existing compound index, verified rather than assumed
- [x] Covered by a new `file-indexer` integration test following the `spaces` pattern — embedded NATS plus a MongoDB testcontainer — exercising paging, prefix boundaries, empty results and ordering stability

## Comments

This ticket took two rounds. The first was rejected for a prefix-boundary defect
the ticket's own example could not have caught; both verdicts are kept below,
because the reasoning behind the fix is the part worth rereading.

### Implementer report (round 1) — base `faff1a6`

- `events/fileindex_list.go` (new) — `FileIndexListRequest`/`Ack`/`Reply` JSON
  structs, plus topic constants in `events/topics.go` (`seraph.fileindex.list`
  with per-request `.ack`/`.reply` patterns), mirroring the existing search
  request's ack-then-stream-reply convention.
- `file-indexer/fileindexer/list.go` (new) — subscribes on the request topic,
  acks, then runs a bounded range scan on the existing unique `(providerId, path)`
  index — no regex. One reply per page with `NextCursor`/`HasMore`; the cursor is
  the last path returned, so ordering follows the index and is stable across pages.
- `file-indexer/main.go` — wires `NewList` into the fx graph.
- `file-indexer/fileindexer/list_integration_test.go` (new) — embedded NATS plus a
  MongoDB testcontainer, following `spaces_integration_test.go`.

**Decisions the ticket did not settle:** modelled the RPC as one-reply-per-page
rather than search's one-reply-per-file, since "paged with a cursor" is a bounded
abstraction; no authorization layer, treating this as an internal service-to-service
query as the ticket frames it; the query returns the prefix path itself plus all
descendants recursively; added `DefaultListPageSize` (500) and `MaxListPageSize`
(5000), which the ticket did not specify. No Avro changes — this RPC uses plain
JSON structs like the existing search request.

### Verifier verdict (round 1) — REWORK

1. **Prefix matching does not respect directory boundaries.** The upper bound
   `clean + "0"` was right, but the lower bound `$gte clean` was open at the
   bottom: every byte below `'0'` (0x30) falls in range, so siblings such as
   `/Photos.txt` (`.` = 0x2E), `/Photos-old` (`-` = 0x2D) and `/Photos backup`
   (space = 0x20) were returned as if beneath `/Photos`. Verified empirically —
   querying `/Photos` returned `[/Photos /Photos-old /Photos.txt /Photos/a.jpg]`.
2. **Test gap that let it ship.** `TestListPrefixDirectoryBoundary` only covered a
   sibling sorting *above* the boundary (`/Photos2`, `2` = 0x32), never one sorting
   below it. The suite passed precisely because that case was never exercised.

Other criteria held: entry fields, empty/unknown prefix, a non-tautological
`explain()` assertion, and a strict `$gt` cursor with no skip/duplicate risk.

### Implementer report (round 2) — commit `1fbf0fb`

**Lower bound closed.** The prefix now selects two disjoint pieces of key space —
the exact prefix path, and the range `[prefix+"/", prefix+"0")` — issued as **two
separate queries** (point lookup plus range scan) rather than one `$or`. This is
the non-obvious part: `explain()` showed the `$or` plan degrading to an IXSCAN with
`[MinKey, MaxKey]` path bounds, scanning the whole provider with `$or` as a
residual filter. It kept the stage name `IXSCAN` while throwing the bounds away, so
a stage-name-only assertion would have passed. A `totalKeysExamined` assertion is
what caught it (100 keys versus 50).

**Test gap closed.** `TestListPrefixDirectoryBoundary` now covers below-boundary
siblings (`/Photos.txt`, `/Photos-old`, `/Photos backup`, `/Photos+1`,
`/Photos,list`) alongside `/Photos2`, plus a new
`TestListPrefixDirectoryBoundaryWhilePaging` since the cursor rewrites the bounds.
The `explain()` test now explains the *real production filters* via `export_test.go`
rather than a re-declared copy, walks `inputStages` branches, and bounds key counts.

**Found and fixed en route:** `nextCursor` was taken from the range results only, so
a page filled entirely by the prefix entry returned an empty cursor and looped
forever.

### Verifier verdict (round 2) — APPROVED

Every claim re-derived independently rather than trusted:

1. Seeded `/Photos`, `/Photos/a.jpg`, `/Photos.txt`, `/Photos-old`,
   `/Photos backup`, `/Photos2` against a live MongoDB testcontainer; prefix
   `/Photos` returned exactly `[/Photos, /Photos/a.jpg]`.
2. `TestListPrefixUsesIndexRangeScan` uses `executionStats` verbosity and asserts
   `totalKeysExamined < 60` against 100 noise docs — a real bound, not a stage-name
   tautology.
3. **Mutation check performed by the verifier**, not taken on faith: reverting the
   lower bound to `clean` failed four tests, including
   `"101" is not less than "60"`. Fix restored, tree confirmed clean. The tests are
   load-bearing.
4. Independent `PageSize=1` test against a self-entry-only first page confirmed
   `HasMore=true` with a non-empty cursor, and full paging with no skip, duplicate
   or infinite loop across the two-query split.
5. Entry fields, empty/unknown prefix and RPC conventions (ack/reply topics,
   `RequestId`/`ReplyId`, `Last` flag) all match `events/search.go`.
6. `export_test.go` exports the actual production `buildPrefixSelfFilter`,
   `buildDescendantsFilter` and `listSort` symbols — no re-declaration, no drift.

Full suite green: 7/7, `ok umbasa.net/seraph/file-indexer/fileindexer 2.458s`.
