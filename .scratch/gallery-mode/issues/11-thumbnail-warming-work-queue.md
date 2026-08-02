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

**Status:** claimed

- [ ] A photo entering the read model results in a Thumbnail at the configured warm size, without anyone requesting it
- [ ] Backfilling a folder of thousands of photos warms all of them, with no silent losses
- [ ] The batch consumer has its own concurrency budget, smaller than the interactive path's, so warming cannot monopolise every worker
- [ ] An interactive preview request stays responsive while a large warm batch is running
- [ ] Work survives a thumbnailer restart — messages are redelivered rather than lost, and are acked only on completion
- [ ] A photo the thumbnailer cannot decode is acked rather than redelivered forever, and the reason is recorded against the gallery item
- [ ] The warm size is configurable, and only that one size is warmed
- [ ] Re-dispatching the same photo is harmless
- [ ] Covered by extending the existing thumbnailer tests for the consumer side, and at the gallery service's NATS boundary for dispatch — asserted as a publish onto the queue
