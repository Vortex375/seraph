# 09 — Re-resolve Gallery Source Folders on `spaces.changed`

**What to build:** An administrator who re-points a Space at a different File
Provider should find the gallery following it, not silently stuck on the old
physical location.

The gallery service holds resolved physical prefixes for each configured Gallery
Source Folder so it can match incoming file-change events without a resolve per
event. That set is a cache. Subscribe to `spaces.changed` and re-resolve
affected folders, so the cache has an invalidation signal rather than being
correct only by luck.

**Blocked by:** 03, 07

**Status:** resolved

- [x] Re-pointing a Space at another File Provider makes the gallery consume events for the new physical path and stop consuming them for the old one
- [x] A Space becoming inaccessible to a user makes their gallery stop returning photos from it
- [x] Deleting a Space leaves its configured Gallery Source Folders harmlessly unresolvable rather than breaking the whole listing
- [x] Re-resolution does not require a service restart
- [x] Events for Spaces no folder references are ignored cheaply
- [x] Covered at the gallery service's NATS boundary: publish a `spaces.changed` event with a changed resolution, then assert that events at the new physical path are accepted and events at the old one are not

## Comments

### Implementer report — `2a6292d`

- `spaceschanged.go` (new) — durable JetStream consumer
  (`SERAPH_GALLERY_SPACES_CHANGED`) on `SERAPH_SPACES_CHANGED`, mirroring the
  `ingest.go` / thumbnailer invalidation pattern. `reactToSpaceChanged` decides
  cheaply whether the changed Space is referenced by any configured Gallery Source
  Folder — one `spaces.crud` READ-by-id plus one Mongo `spaceProviderId $in`
  query — and only then calls the existing `refreshPrefixCache`.
- `gallery.go` — consumer wired into `Start`/`Stop` alongside the ingest consumer
  and backfill lifecycle.
- `spaceschanged_integration_test.go` (new) — a mutable stub `spaces` responder
  answering `spaces.resolve` and `spaces.crud` and publishing real
  `spaces.changed` events, plus four tests: re-point accepts the new physical path
  and rejects the old, access revocation stops a user's listing, Space deletion
  leaves one folder unresolvable without breaking the user's other folders, and an
  unrelated Space's change triggers zero `SpaceResolveRequest`s.

**Decision the ticket did not settle.** The event carries only `spaceId` and a
change kind, never the Space's `fileProviders`. For `created`/`updated` the Space
is read back to test relevance cheaply. For `deleted` the document is already gone
when the event arrives, so relevance cannot be determined and the cache is always
refreshed — deletions are rare admin actions rather than a hot path, and there is
no cheaper option that stays correct.

### Verifier verdict — APPROVED

- `prefixCache.set` genuinely REPLACES the slice, so old prefixes are dropped
  rather than joined by the new ones — confirmed by reading the code and by the
  re-point test proving old-path rejection.
- Relevance filtering matches on the stable `spaceProviderId`, which survives a
  re-point (only `providerId`/`path` change), so re-points are correctly
  classified relevant while unrelated Spaces are skipped with a single RPC plus one
  Mongo query. Proven with a real zero-vs-nonzero resolve counter and a harness
  sanity check.
- Deletion leaves the folder unresolvable without breaking the user's other
  folders, and ingestion for the old path stops.
- No restart needed — durable consumer, tested with `require.Eventually` against a
  live provider rather than a restart.

**Regression check against the approved tickets 07 and 08:** `query.go` and
`backfill.go` are untouched by this diff (empty diffs confirmed).
`resolveFoldersForUser` still resolves fresh per call and remains uncached;
`backfillUpsert` is still `$setOnInsert`-only; no reverse physical-to-space
mapping introduced.

**On the "deleted always refreshes" decision:** judged sound. It is the one case
where relevance genuinely cannot be determined cheaply, and the cost is bounded —
one refresh, matching what ADD already pays. A deletion burst could cause repeated
refreshes proportional to burst size × folder count with no debounce, but
deletions are rare and admin-driven. A reasonable trade, not a defect.

Both modules clean on `go build` and `go vet`; full `gallery` suite passes
including the four new boundary tests; `api-gateway` passes with `-p 1`.
