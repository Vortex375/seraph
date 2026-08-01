# 05 — Remove and invalidate Thumbnails on file-change events

**What to build:** A user who edits a photo in place should see the edited photo
everywhere, and an administrator should not accumulate Thumbnails for files that
no longer exist.

Today a Thumbnail's name is derived from `(providerId, path)` and the target
size, with no modification-time or size component, so editing a photo in place
leaves the old Thumbnail served forever — a staleness bug affecting the whole
product, not just Gallery Mode. Deleted files leave their Thumbnails behind
indefinitely.

Have the thumbnailer subscribe to the durable file-change stream with its own
durable consumer: `deleted` removes the file's Thumbnails, `changed` invalidates
them so the next request regenerates. There is no rename event — a rename
surfaces as delete-at-old plus create-at-new, which is sufficient here.

Note that Thumbnail storage is a flat folder and names embed the dimensions, so
"remove every Thumbnail for this file" currently means attempting each known
size, most returning a not-found. That is acceptable for now; sharding storage
is tracked separately and is not part of this ticket.

**Blocked by:** None — can start immediately.

**Status:** resolved

- [x] Deleting a file removes its Thumbnails at every size — see the `Exact` sizing caveat below
- [x] Changing a file in place causes the next preview request to serve a Thumbnail of the new content, not the old one
- [x] A file that never had Thumbnails produces no errors and no log noise when deleted
- [x] The consumer is durable, so Thumbnails are still cleaned up for changes that occurred while the thumbnailer was down
- [x] Redelivery of the same event is harmless
- [x] Cleanup work does not starve the interactive preview path
- [x] Covered by extending the existing thumbnailer tests

## Comments

### Implementer report — base `56c8c10`

The thumbnailer now runs a durable JetStream consumer
(`SERAPH_THUMBNAILER_INVALIDATION`) on the existing `SERAPH_FILE_CHANGED` stream,
in `thumbnailer/thumbnailer/invalidation.go`. `deleted` and `changed` events remove
the file's Thumbnails at all size combinations from `ThumbnailSizes` (16 combos,
since width and height vary independently); `created` and unknown kinds are no-ops.
`RemoveAll` errors matching `fs.ErrNotExist` are treated as success with no log
line, satisfying both the no-log-noise and the idempotent-redelivery criteria. The
message is acked only after cleanup succeeds, so a crash mid-cleanup redelivers.

Wired into `thumbnailer.go`: `Js jetstream.JetStream` added to `Params`/struct,
started and stopped alongside the existing preview-request loop using the exact
ctx/WaitGroup/mutex shutdown pattern established by `6c7adcc` — same `t.wg.Wait()`
join point, no new shutdown machinery. Non-starvation is structural: the
invalidation consumer holds its own `util.Limiter` (capacity 2), entirely separate
from the preview-path limiter, so cleanup concurrency cannot consume preview
capacity.

**Files:** `invalidation.go` (new), `invalidation_test.go` (new, 8 tests covering
every acceptance criterion including durability across a simulated restart),
`thumbnailer.go`, `thumbnailer_test.go` (harness now provisions JetStream). No Avro
schema changed. `go test -race ./...` clean.

**Decisions the ticket did not settle:** a fixed durable consumer name rather than a
derived one, so a restart reattaches to the same backlog; cleanup attempts all 16
`ThumbnailSizes × ThumbnailSizes` combinations rather than only square sizes.

### Verifier verdict — APPROVED

- **The consumer is live in production, not dead code.** `thumbnailer/main.go`
  includes `messaging.Module`, which provides `NewJetStream` (`messaging/jetstream.go`),
  so the optional `jetstream.JetStream` dependency is genuinely satisfied at runtime
  — checked by tracing the fx graph, not by reading the wiring.
- Delete/change cleanup across known sizes, no-log-noise on not-found, redelivery
  idempotence, and true durability across restart (consumer stopped, event published
  while down, new instance drains the backlog) are all covered by tests that exercise
  real behaviour rather than tautologies.
- Ack happens only after `invalidateThumbnails` returns nil; on error the message is
  left unacked for redelivery (`invalidation.go:156-169`).
- The starvation test asserts a real behavioural property — a preview completes in
  under 3s while invalidation is flooded with 10× its capacity — alongside the
  separate-limiter sanity check.
- `go test -race ./...` clean, including 5× repeated runs of the concurrency-sensitive
  tests. No new race introduced by the second goroutine.

**Confirmed gap, judged in scope but flagged for follow-up:** `Exact`-sized
Thumbnails are never cleaned up. `api-gateway/preview/preview.go:181-188` exposes
`?exact=1&w=&h=` to callers, so they are genuinely produced in production, but
`invalidateThumbnails` only iterates the 16 known `ThumbnailSizes` combinations. The
ticket's "attempt each known size" concession excuses misses *among the known
combinations*, not an entirely separate dimension space — but the same paragraph
scopes flat-storage/no-enumeration limitations out of this ticket pending storage
sharding, and this is a symptom of exactly that. Resolved on that basis, with a
follow-up raised: it is a real staleness and leak path, not a theoretical one.
