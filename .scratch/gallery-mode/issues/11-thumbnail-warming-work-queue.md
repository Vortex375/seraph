# 11 — Thumbnail warming work queue

**What to build:** Thumbnails for photos in Seraph are ready before the user
scrolls to them, so the gallery is a grid of pictures rather than a grid of grey
placeholders. Warming happens in the background without making the rest of
Seraph unresponsive, and a user waiting on a photo they are looking at right now
is never queued behind a backfill batch.

Dispatch pre-generation through a **new durable work queue**, published
fire-and-forget by the gallery service as items enter the read model, consumed
by the thumbnailer with ack-on-completion. The existing interactive
request/reply preview path is untouched.

The failure this avoids is specific and must not be reintroduced: the
thumbnailer is a core-NATS request/reply service with concurrency capped at the
CPU count. Firing eight thousand backfill requests at it times out replies,
breaches the pending-message limit, and **core NATS silently drops the
overflow** — leaving no record of which Thumbnails were never made.

**Warm exactly one configurable size**, 512 the realistic default: a
three-column grid on a 1080p phone needs roughly 360 px per cell and sizes snap
upward. Larger viewer sizes stay on demand. That is roughly 320 MB for 8,000
photos rather than over a gigabyte for all four sizes.

**Blocked by:** 07

**Status:** resolved

- [x] A photo entering the read model results in a Thumbnail at the configured warm size, without anyone requesting it
- [x] Backfilling a folder of thousands of photos warms all of them, with no silent losses
- [x] The batch consumer has its own concurrency budget, smaller than the interactive path's, so warming cannot monopolise every worker
- [x] An interactive preview request stays responsive while a large warm batch is running
- [x] Work survives a thumbnailer restart — messages are redelivered rather than lost, and are acked only on completion
- [x] A photo the thumbnailer cannot decode is acked rather than redelivered forever, and the reason is recorded against the gallery item
- [x] The warm size is configurable, and only that one size is warmed
- [x] Re-dispatching the same photo is harmless
- [x] Covered by extending the existing thumbnailer tests for the consumer side, and at the gallery service's NATS boundary for dispatch — asserted as a publish onto the queue

## Comments

### Implementer report

New durable JetStream work queue `SERAPH_THUMBNAIL_WARM` for thumbnail
pre-generation, replacing what would otherwise be a flood of core-NATS
interactive requests during backfill.

- `events/topics.go`, `events/thumbnail_warm.go` — stream/topic constants and two
  plain-JSON messages, following the `FileIndexListRequest` precedent rather than
  avro.
- `thumbnailer/thumbnailer/warm.go` — durable consumer `SERAPH_THUMBNAILER_WARM`
  mirroring the ticket-05 invalidation consumer's shape.
- `thumbnailer.go`, `main.go` — `Options.WarmSize`, default 512, wired through
  fx/viper as `thumbnailer.warmSize`.
- `gallery/gallery/warm.go` — fire-and-forget dispatch, plus a consumer that
  writes a reported reason onto `GalleryPhoto.Unsupported`.
- Dispatch wired into `upsertPhoto` and into `backfillUpsert` gated on genuine
  insert (`UpsertedCount > 0`).

**Concurrency budgets:** interactive preview stays at `Options.Parallel`
(CPU count); invalidation stays at 2; the new warm consumer is 1 — the smallest of
the three, on its own limiter instance.

**Undecodable reason:** the thumbnailer maps its `ErrorClassUnsupportedFormat` /
`ErrorClassCorrupt` onto the gallery's existing `"format"`/`"corrupt"` vocabulary
— duplicated rather than imported, since the thumbnailer cannot depend on the
gallery module — and publishes a notice fire-and-forget. `ErrorClassTooLarge` is
acked but not reported: the image does decode, it is a policy limit, and the
ticket forbade inventing a new reason.

**Bug caught during implementation.** The warm consumer's loop originally
pre-acquired the capacity-1 limiter before calling `handleRequest`, which acquires
the same limiter — a guaranteed self-deadlock past the first in-flight message.
Fixed by delegating limiting entirely to `handleRequest`, matching the interactive
path.

### Verifier verdict — APPROVED

- Warm requests genuinely flow through durable JetStream `WorkQueuePolicy` streams
  with `AckExplicitPolicy` consumers, never core NATS request/reply. The
  interactive path is untouched.
- The no-silent-loss test polls DISK for actual thumbnail existence across the
  dispatched photos rather than merely asserting absence of error.
- Three independently constructed limiter instances confirmed, with an explicit
  `NotSame` assertion and a test that an interactive preview stays responsive
  during a large warm batch.
- Ack occurs only after completion; redelivery after restart genuinely exercised.
- Only the configured size is warmed. Re-dispatch is harmless: `handleRequest`'s
  stat-based "already exists" short-circuit runs BEFORE the limiter acquire.
- The self-deadlock fix is real; no double-acquire remains in the warm path.

**On `warmParallel = 1`:** a real throughput concern — serial JPEG decode and
encode over 8,000 photos runs to hours — but it structurally guarantees the
ticket's hard requirement that the interactive path is never starved. Judged a
legitimate documented trade-off rather than a defect. **Worth revisiting if
warming proves too slow in practice; raising it slightly would still satisfy
"smaller than the interactive path".**

**On `ErrorClassTooLarge`:** correctly judged out of scope. The image does decode
— metadata reading succeeds — so it is a policy limit rather than "cannot decode",
and the gallery's vocabulary genuinely has no slot for it.

**Regression checks** against 07/08/09/10 all hold. `backfillUpsert`'s
`$setOnInsert` body is byte-for-byte unchanged; only `UpsertedCount` is now
captured to gate dispatch.

### Follow-up applied by foreman direction — `3efe1e1`

The verifier flagged, as orthogonal to this ticket's criteria, that
`recordUnsupported` did a bare `$set` outside `withSequence` and so never bumped
`seq` — meaning a mirror that had already polled past that document would never
learn the photo became unsupported. That is inconsistent with `markDeleted`, which
bumps the sequence for exactly this kind of flag-an-existing-document write, and
ticket 10 exists precisely so mirrors learn about changes to documents they have
already seen. Fixed rather than deferred.

`recordUnsupported` now routes through `withSequence`, so the write is
watermark-covered and released on every exit path including errors. Duplicate
notices cannot churn the feed: the filter carries `"unsupported": {$ne: reason}`,
so a redelivered notice for an already-recorded value matches zero documents,
writes nothing and bumps no sequence — the allocated-but-unused sequence is simply
skipped, the same reasoning `backfillUpsert` already documents.

`TestUnsupportedNoticeReachesAMirrorThatAlreadyPolledPastThePhoto` covers the full
cycle: poll, flag, re-poll (arrives exactly once with the reason), duplicate
notice, re-poll (absent).
