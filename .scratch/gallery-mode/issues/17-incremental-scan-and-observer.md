# 17 — Incremental scan and content-observer trigger

**What to build:** A photo taken right now appears in the gallery within
seconds, rather than at the next full scan.

Two mechanisms on top of the full scan, with strictly non-overlapping roles: a
**generation-based incremental scan** as the fast path, available
unconditionally at the app's minimum SDK level; and a **content observer** as a
*trigger only*, not a source of truth.

**The governing rule: no photo's backup status may ever depend on having
received a notification.** A missed notification must degrade latency, never
correctness — which is exactly what the full scan from the previous ticket
guarantees, and why it stays.

**Blocked by:** 15

**Status:** resolved

- [ ] Taking a photo makes it appear in the gallery within seconds while the app is running
- [ ] The incremental scan processes only photos changed since the last watermark, not the whole library
- [ ] The watermark survives an app restart
- [ ] A photo added while the app was not running is picked up by the next full scan
- [ ] Suppressing every content-observer notification leaves the gallery eventually correct, with latency the only casualty — verified explicitly
- [ ] A burst of changes does not trigger a storm of scans
- [ ] The observer is registered and released with the app's lifecycle and does not leak
- [ ] Covered at the app's mirror seam by driving the fake Local Source, including a test that delivers no notifications at all and asserts eventual correctness

## Comments

### Implementer report (commit efde72e)

A generation-based incremental scan (fast path) and a content-observer trigger,
both strictly non-load-bearing for correctness — the full scan from ticket 15
remains the only place a device photo is ever removed.

- `MainActivity.kt` — new `incrementalScan` / `currentGeneration` channel methods
  using MediaStore's `GENERATION_MODIFIED` column and `MediaStore.getGeneration`
  (unconditional at minSdk 34, no version gate needed); a `ContentObserver`
  registered in `onStart` and unregistered in `onStop`, forwarding a payload-free
  `onLocalMediaChanged` trigger to Dart.
- `lib/src/gallery/local/` — `LocalSource` gained `incrementalScan()`,
  `currentGeneration()` and a `changes` stream; `AndroidLocalSource` implements
  them, failing safe (empty items, unchanged watermark) exactly as `fullScan`
  already does.
- `GalleryMirror` gained `applyLocalDelta` (upsert-only — never removes or demotes
  a row, so deletion detection stays `applyLocalScan`'s alone) and a
  `localGeneration` / `primeLocalGeneration` watermark reusing the `SyncCursors`
  table.
- `LocalScanService` gained `incrementalScan()` and `watchForChanges()` /
  `stopWatchingForChanges()` with debounced, coalesced scanning, so a notification
  burst becomes one scan. `GalleryGridController` subscribes in `open()` and
  unsubscribes in `onClose()`.
- Tests: `FakeLocalSource` extended with generation / incrementalScan / changes;
  coverage added in `local_scan_service_test.dart`, `gallery_local_scan_test.dart`,
  `gallery_grid_controller_test.dart` and `android_local_source_test.dart`,
  including the required explicit test that never emits a single content-observer
  notification and asserts the gallery still becomes correct through `scan()`
  alone.

`flutter test` 193/193, `flutter analyze` 45 pre-existing issues (none new),
`flutter build web --release` and `flutter build apk --debug` both succeed.

Decisions the ticket did not settle:

1. Debounce window defaults to 750ms (constructor-overridable) — no criterion
   specified a duration, only "no storm".
2. The native-to-Dart trigger reuses the existing `seraph/local_media`
   MethodChannel bidirectionally rather than adding a second EventChannel —
   simpler, and keeps one channel to reason about.
3. `currentGeneration()` failures degrade to watermark 0, so the next incremental
   scan replays the whole library once — self-healing, never incorrect, just a
   one-time efficiency loss.

### Verifier verdict

APPROVED. Every acceptance criterion met, checked against the code rather than the
commit message:

- Incremental scan is watermark-scoped: `handleIncrementalScan` adds a single
  indexed `GENERATION_MODIFIED > ?` filter to the same projection-only query.
- The watermark persists via `SyncCursors` — the same drift-backed table the delta
  feed's cursor already uses — confirmed by a test that builds a second
  `LocalScanService` sharing the mirror to simulate a restart.
- The governing rule holds structurally, not merely by test name:
  `applyLocalDelta` never deletes or demotes a row (only `applyLocalScan` walks
  `previouslyOnDevice`), and the native incremental query can only report
  additions and modifications, never absence. `applyLocalScan`'s
  deletion/demotion logic is untouched, only refactored to share
  `_upsertLocalItem`.
- The no-notification test never calls `watchForChanges` at all — not merely
  suppressing emitted events — then asserts `scan()` alone reaches correctness
  with `incrementalScanCount == 0`.
- Burst coalescing: debounce timer plus pending-scan flag, tested with 20 rapid
  `emitChange()` calls collapsing to one scan.
- Lifecycle: `ContentObserver` registered/unregistered in `onStart`/`onStop`, Dart
  side wired to `open()`/`onClose()`, with an explicit "no scan after onClose"
  test.
- Photo added while the app was not running: explicit test plus the structural
  guarantee that `syncNow()` unconditionally calls `scanner.scan()` on every
  `open()`, independent of the observer.

`flutter test` 193/193, `flutter analyze` 45 issues all pre-existing (none in the
touched files), `flutter build web --release` and `flutter build apk --debug` both
succeed.
