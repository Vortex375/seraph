# 10 — Delta feed with tombstones

**What to build:** A client that has seen every gallery change up to a point can
ask for everything after it and miss nothing — including removals. This is what
lets the app hold a local mirror instead of re-listing the whole gallery, and it
is how "my other phone uploaded 200 photos" becomes discoverable at all.

Every read-model document carries a **monotonic sequence** bumped on every
change. **Removals produce tombstone rows, not deletions** — a mirror without
tombstones silently keeps showing photos that no longer exist. The client polls
with the last sequence it saw and receives a page of changed items plus a cursor
to continue from.

The feed is scoped to the requesting user's Gallery Source Folders, resolved at
request time, so it inherits exactly the same access control as the listing.

Cursor semantics and page sizing are open; the requirement is that a client
which has seen everything up to a sequence and asks for everything after it
misses nothing, and that the feed is resumable across app restarts.

**Blocked by:** 07

**Status:** resolved

- [x] A client polling from a given sequence receives every item changed since, and nothing it has already seen
- [x] A deleted photo arrives as a tombstone, so a mirror can remove it
- [x] A photo that changes twice between two polls is delivered once, in its current state
- [x] The feed is paged, with a cursor that survives an app restart
- [x] Polling from sequence zero yields the user's entire gallery, so a mirror can cold-start from the feed alone
- [x] A folder added or removed between polls is reflected without the client needing to know it happened
- [x] The feed returns Space paths, consistent with the listing
- [x] A user never receives items from another user's folders, and revoked access stops delivery
- [x] Sequence values are monotonic and never reused, including across service restarts
- [x] Covered at the gallery service's NATS boundary, including a test that publishes changes between two polls and asserts nothing is missed and nothing is duplicated

## Comments

One implementer, one REWORK round. The rework was interrupted by a session limit
with the work complete but uncommitted; the foreman reviewed, ran the suite and
committed it as `36e96e2`.

### Implementer report — `7dfa107`

`sequence.go`, `delta.go`, `delta_integration_test.go`, migration `000003`; plus
`Seq` on `GalleryPhoto`, a `PhysicalProviderId`/`PhysicalPath` cache on
`GallerySourceFolder`, delta message types, and `GET /gallery/delta`.

Sequences come from a single Mongo counter document incremented with
`findOneAndUpdate`+`$inc` — durability from Mongo rather than process memory, so
restarts cannot restart the sequence; atomicity from Mongo's per-document update
guarantee, so ingest, backfill and delete allocate safely in parallel.

Keyset cursor over `seq` ascending, never skip/limit. Page size 500, max 2000.
Opaque base64 cursor, safe to persist and resume after an app restart.

Folder ADD bulk-bumps `Seq` on already-ingested documents so they re-enter the
scan and are freshly translated. Folder REMOVE cannot rely on later translation —
the folder is gone by scan time — so removal tombstones are computed at removal
time into a small per-user `galleryPendingTombstones` outbox, reading the physical
prefix cached on the folder document rather than re-resolving, which preserves
REMOVE's tested "contacts no other service" contract.

### Verifier verdict 1 — REWORK

1. **Sequence-gap visibility race.** Allocation and the document write are
   separate operations and the writers are genuinely concurrent
   (`ingestParallel=4`, `backfillParallel=2`). Writer B could commit seq 6 while
   writer A still held seq 5 unwritten. `NextSince` advanced to the max seq
   observed, so a client polling in that window advanced past 6 and seq 5's
   document landed permanently BELOW its cursor — silent, unrecoverable loss from
   that mirror. Every delta test was sequential, so the suite was green.
2. **`galleryPendingTombstones` grew without bound** — one row per photo per user
   on every REMOVE, with no TTL and no pruning anywhere in non-test code.
3. **Stale cached physical prefix produced WRONG tombstones.** `cachePhysicalPrefix`
   was written only from `addSourceFolder`; `spaces.changed` refreshed only the
   in-memory ingestion cache. After a Space re-point, a REMOVE emitted tombstones
   scoped to the old physical path, so mirrors failed to remove the photos that
   actually went away.

### Rework — `36e96e2`

**The race** is closed with a safe watermark in `sequence.go`: an
allocated-but-unwritten sequence is held in `inFlight` until its write returns,
and the feed never serves at or beyond the lowest in-flight value. The allocator
mutex is deliberately held ACROSS the Mongo round trip rather than only around the
map insert — releasing earlier would leave a window where a value is allocated but
not yet registered, during which the watermark would report "nothing in flight"
and the feed could serve straight past that allocation.

**SINGLE-INSTANCE ASSUMPTION.** `inFlight` is per-process memory, so the fix is
exact for exactly one gallery service instance. Two instances against one database
each see only their own allocations, silently reintroducing the data-loss bug.
This is documented in capitals at the type level in `sequence.go`, naming the two
viable replacements (a time-based safety lag, or a shared/coordinated watermark).
It is the only single-instance assumption in the service.

**Tombstones** bounded by migration `000004`: a 30-day TTL index on `createdAt`.

**The stale prefix** is fixed by having `refreshPrefixCache` persist
`PhysicalProviderId`/`PhysicalPath` onto the folder document whenever the resolved
prefix differs — so it now runs on startup, ADD and `spaces.changed` alike — with
`removeSourceFolder` reading that persisted field. The inaccurate "best-effort
sweep" comments were corrected.

`TestDeltaConcurrentWritersLoseNothing` added: 6 concurrent publisher goroutines
against real ingestion parallelism while a poller advances its cursor live.

### Verifier verdict 2 — APPROVED

All three defects genuinely fixed at code level, not relocated.

- `nextPhotoRows`/`nextTombstoneRows` both apply `"seq": {"$gt": pos, "$lte":
  watermark}`, with the watermark captured once per request — the feed genuinely
  consults it.
- All five write paths go through `withSequence`, which `defer release()`s, so
  errors, panics and early returns all release. A restart clears `inFlight`, which
  is harmless: an allocated-but-never-written sequence becomes a permanent gap
  rather than a stall, since the watermark excludes only CURRENTLY in-flight
  values.
- The TTL targets a genuine BSON date (`CreatedAt time.Time`), not a string — the
  classic silent-failure mode for TTL indexes — via the standard embedded-JSON
  migration mechanism.
- The concurrency test is a real regression test with a 10s-deadline condition
  that fails the run, not a goroutine-spawning placebo.

Regression checks against 07/08/09 all hold. Build and vet clean on both modules;
`gallery` passes with `-race`; `api-gateway` passes with `-p 1`.

**Minor gap accepted, not blocking:** no integration test exercises
re-point-then-REMOVE end to end at the delta feed. The code path is sound by
inspection and both halves are tested separately. Worth a follow-up test.

### Decisions the ticket did not settle

- Page size 500, max 2000, mirroring the listing's 200/1000.
- Tombstones for documents never visible to the requesting user are silently
  skipped rather than emitted with empty identity, avoiding cross-user noise.
- `NextSince` is the max seq observed across a full poll, returned only once
  `HasMore` is false.
- 30-day tombstone TTL: a client that polls less often than that must cold-start
  from sequence zero. Documented in `delta.go`.
