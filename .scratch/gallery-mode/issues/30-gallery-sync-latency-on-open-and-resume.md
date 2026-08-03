# 30 — Gallery sync latency on open and resume

**What to build:** Opening Gallery Mode — or resuming the app onto it — stops
blocking on a ~30 second sync. The gallery becomes usable immediately and
thumbnails keep loading while any sync runs.

**Blocked by:** 15, 16, 17, 28

**Status:** resolved

## The diagnosis this ticket acts on

Three findings, all confirmed by reading the code. Do not re-derive them, but do
check each fix actually lands where the finding says it does.

1. **The mirror has no indexes.** `gallery_mirror_database.dart` declares exactly
   one `uniqueKeys` entry, `(providerId, path)`, and nothing else.
   `GalleryMirror._upsertLocalItem` runs a `SELECT` on
   `(localRelativePath, localDisplayName, localSize, localDateTaken)` per device
   photo, and often a second on `(origin, size, capturedAt)` — each a full table
   scan. A full scan of N device photos against an M-row mirror is O(N×M) row
   visits. `queryItems` orders by `capturedAt` with no index, so every grid page
   read is a full scan plus sort, and `availabilitySummary()` is three unindexed
   `COUNT`s on every `reload()`.

2. **The interactive path always runs the *full* scan.** `LocalScanService.scan()`
   is the full MediaStore scan. `incrementalScan()` — ticket 17's generation-based
   fast path — is wired only to the content observer, never to gallery open or
   app resume, which are the two paths the user actually waits on.

3. **Nothing throttles the sync.** `GalleryGridController` is registered
   `Get.lazyPut(..., fenix: true)`, so every navigation back to the gallery builds
   a fresh controller → `onInit` → `open()` → `syncNow()`. Separately,
   `GalleryView.didChangeAppLifecycleState` calls `syncNow()` on every `resumed`.
   There is no persisted "last synced at" anywhere to gate either.

## What to change

### Indexes (schema v4)

Add to `GalleryItems`, via drift's `@TableIndex` annotations, and regenerate
(`dart run build_runner build --delete-conflicting-outputs` from
`app/seraph_app/`):

- `(localRelativePath, localDisplayName, localSize, localDateTaken)` — the local
  identity probe.
- `(origin, size, capturedAt)` — the dedup probe on both sides
  (`applyPage`'s device match, `_upsertLocalItem`'s cloud match). `origin` is the
  leftmost column, so `availabilitySummary()`'s counts use this index too; do not
  add a fourth index for `origin` alone.
- `(capturedAt, id)` — the grid's ordering. Declared ascending: SQLite traverses
  an ascending index in reverse for `ORDER BY ... DESC`, so this serves
  `queryItems`/`queryPage` without a `DESC` index.

Bump `schemaVersion` to 4 and add a real `onUpgrade` step that creates the
indexes on existing installs. **It must not drop or recreate `GalleryItems`** —
the existing migration's own doc comment explains why losing the mirror or the
sync cursor on upgrade is unacceptable.

### Incremental scan on the interactive path

`syncNow()` must no longer run a full `scan()` unconditionally. Full scan when,
and only when:

- nothing has ever scanned (`mirror.localGeneration() == 0`), or
- the last full scan is older than a backstop interval (use 6 hours; make it a
  named constant), or
- the caller forced it (below).

Otherwise run `incrementalScan()`.

Persist the last-full-scan timestamp the same way ticket 17 persisted its
watermark: another `SyncCursors` row under its own source constant, epoch
milliseconds in the `since` column. No new table.

**Ticket 17's governing rule still holds and must be visibly preserved:** the
full scan remains the correctness anchor and the only thing that removes a
device photo from the mirror. This ticket changes its *cadence*, not its role.
Update `LocalScanService`'s class doc, which currently claims the full scan runs
"whenever `GalleryGridController` refreshes the gallery" and is "unconditional,
periodic, never skipped" — after this ticket it is periodic and forced, not
unconditional. A doc comment left asserting the old contract is a defect.

The accepted tradeoff, which the code should state where the decision lives: a
device photo deleted outside the app can linger in the mirror until the next
full scan (at most the backstop interval, or immediately on a manual refresh),
because an incremental scan cannot see deletions.

### Throttle

Give `syncNow()` a `force` parameter (default false) and a persisted
last-synced-at timestamp, again a `SyncCursors` row. When not forced and the
last sync completed within a throttle window (use 60 seconds; named constant),
`syncNow()` returns immediately without touching the network, the media store or
the spinner.

Forced — bypassing the throttle *and* running a full scan:

- the app bar's refresh button (`gallery_view.dart`),
- `requestLocalPermission()`, which already calls `syncNow()` and must still show
  a newly granted or widened selection immediately.

**Do not regress ticket 16's "changing the grant while the app is running is
picked up without requiring a restart".** The resume handler currently satisfies
that criterion only because it syncs unconditionally. Under the throttle it must
still re-read `localScanService.permissionStatus()` on every resume, and force a
full sync when the status differs from the last known one. Returning from system
Settings with a newly granted permission must not be swallowed by the throttle.

## Out of scope

Tier 2 of the investigation — batching the mirror writes, chunking the giant
`applyLocalScan` transaction, splitting `MainActivity`'s single-thread executor,
and replacing `reload()`'s clear-everything behaviour. Name anything you notice
in your report; do not build it here.

- [ ] The three indexes above exist on `GalleryItems` and are created by a schema-v4 migration that preserves existing rows and the sync cursor
- [ ] Opening the gallery, or resuming onto it, runs an incremental scan rather than a full scan when a full scan has run recently
- [ ] A full scan still runs on a cold start, past the backstop interval, and whenever a caller forces one
- [ ] A second `syncNow()` within the throttle window is a no-op: no HTTP request, no media-store call, no spinner
- [ ] The refresh button and `requestLocalPermission()` both force, bypassing the throttle and running a full scan
- [ ] A photo-permission change made while the app is backgrounded is still picked up on resume, throttle notwithstanding (ticket 16)
- [ ] The full scan remains the only path that removes or demotes a device row, and `LocalScanService`'s docs describe the cadence the code actually has
- [ ] Covered at the mirror seam by driving the fake Local Source and a fake clock — including a test that asserts the throttled call issues no scan at all, and one that asserts a permission change on resume defeats the throttle
- [ ] `flutter test` passes and `flutter build web --release --base-href=/app/` succeeds

## Comments

### Implementer report (commit b7d7ccd)

**Indexes (schema v4):** `@TableIndex` annotations on `GalleryItems` in
`gallery_mirror_database.dart` for
`(localRelativePath, localDisplayName, localSize, localDateTaken)`,
`(origin, size, capturedAt)` and ascending `(capturedAt, id)`. `schemaVersion`
bumped to 4 with a `from < 4` step that calls `createIndex` on existing installs
without touching `GalleryItems` itself. `gallery_mirror_database.g.dart`
regenerated via build_runner.

**Cadence:** `GalleryGridController.syncNow()` takes a `force` parameter, is
throttled to 60s (`syncThrottleWindow`), and runs a full `LocalScanService.scan()`
only when no full scan has ever completed or one is overdue by 6 hours
(`fullScanBackstopInterval`) — otherwise `incrementalScan()`. New
`syncOnResume()`, called by `GalleryView`'s resume handler in place of
`syncNow()`, re-checks the permission grant and forces past the throttle when it
changed. The refresh button and `requestLocalPermission()` both force. New
`GalleryMirror` methods (`lastFullScanAt`/`recordFullScanAt`,
`lastSyncedAt`/`recordSyncedAt`) persist both watermarks as `SyncCursors` rows.

**Decision the ticket did not settle:** the ticket specified detecting "nothing
has ever scanned" via `mirror.localGeneration() == 0`. That watermark is primed
from the Local Source's own generation counter, which can legitimately be 0, so
it would force a full scan on every sync forever once that happened. Used the new
`lastFullScanAt` watermark instead, written only when a full scan actually
completes. Deviation documented in the code.

**Second issue found and fixed in passing:** the added `_fullScanIsDue` await
shifted timing enough to expose a latent bug — `syncNow()`'s
`reload()`/`recordSyncedAt()` tail was not exception-guarded, so an unawaited
background sync could throw uncaught. Wrapped in its own try/catch, consistent
with the method's stated "failure is not fatal" contract.

**Tests:** extended `gallery_grid_controller_test.dart` (throttle no-op,
incremental-vs-full cadence, backstop, permission-defeats-throttle, existing
widen-grant test moved to `syncOnResume`), `gallery_mirror_test.dart` (watermark
methods) and `gallery_mirror_database_test.dart` (v3→v4 migration preserving rows
and cursor, all three indexes created). `FakeClock` added to
`gallery_test_support.dart`.

Both gates pass: `flutter test` (225/225) and
`flutter build web --release --base-href=/app/`.

**Left out of scope, as the ticket directed:** batching the mirror writes,
chunking `applyLocalScan`'s transaction, splitting `MainActivity`'s executor, and
`reload()`'s clear-everything behaviour.

### Verifier verdict (against base 8ad3c45): APPROVED

Every acceptance criterion checked against the diff, not the commit message.

1. The three `@TableIndex` column lists match the ticket exactly; the `onUpgrade`
   step only calls `createIndex` — no `createTable`, no drop.
   `gallery_mirror_database_test.dart` builds a real v3 sqlite file with data,
   upgrades it, and asserts the row and the `sync_cursors` row both survive and
   all three indexes exist by name in `sqlite_master`.
2. `syncNow()` throttles on a cached `lastSyncedAt` (60s, named constant) and runs
   `scan()` only when `_fullScanIsDue` (cold start, 6h backstop, or `force`);
   otherwise `incrementalScan()`. Refresh button and `requestLocalPermission()`
   both pass `force: true`.
3. `syncOnResume()` re-reads `permissionStatus()` and forces when it differs from
   `localPermission.value`, satisfying ticket 16 under the throttle; covered by a
   test that fires inside the throttle window with a `FakeClock`.
4. `LocalScanService.scan()` remains the only path into
   `GalleryMirror.applyLocalScan` (unchanged), so the full scan is still the only
   thing that removes or demotes a device row. Its class doc now reads "periodic
   and forced, not unconditional, but never skipped"; grep confirms no remnant of
   the old wording.
5. The `lastFullScanAt`-for-`localGeneration()` deviation holds up: `scan()`
   primes `localGeneration` from the platform counter after every full scan
   including the first, so a platform whose counter starts at 0 would make
   `localGeneration() == 0` misfire as "never scanned" permanently.
   `lastFullScanAt` is written only after a full scan completes, and a missing row
   reads back as 0, so a genuine cold start still forces one.
6. `flutter test`: 225/225 pass. `flutter build web --release --base-href=/app/`
   succeeds (only pre-existing wasm/font tree-shaking warnings).

Flagged, not a defect: `_runLocalScan`'s failure path still drops a failed full
scan silently beyond ticket 16's permission UI — the tradeoff the ticket states.
