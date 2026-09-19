# 22 — Headless sync engine and foreground data-sync service

**What to build:** A user starts a backup run and it keeps going with the screen
off, showing progress in a notification. They can pause and resume it, and see
how many photos remain and roughly how much data.

The sync engine moves into a **headless Dart isolate**, driven here by a
foreground data-sync service for user-initiated batches. The manifest currently
declares only the media-playback foreground service type and needs the data-sync
type added.

**The engine is headless by construction**: no GetX controllers, no build
context, no UI dependencies. **The local database is the interface between the
engine and the UI** — the engine writes state, the UI observes and renders. This
is a deliberate departure from the rest of the app, where controllers hold
reactive state, and it is what makes the engine runnable with no UI attached at
all.

A native engine was rejected: it would duplicate the state machine, database
access and auth handling outside Dart.

Unattended background scheduling comes later and depends on the cross-isolate
token lock landing first.

**Blocked by:** 20

**Status:** resolved

- [ ] A user-initiated backup run continues with the app backgrounded and the screen off
- [ ] Progress — photos remaining and approximate data volume — is visible in a notification and in the app
- [ ] The run can be paused and resumed, and pausing takes effect promptly
- [ ] The engine contains no UI dependencies and can run with no UI attached
- [ ] The UI reflects engine state by observing the local database, not by being called by the engine
- [ ] Killing and restarting the app mid-run leaves no item in a stuck intermediate state
- [ ] The engine and the UI can both touch the database without corrupting it
- [ ] The manifest declares the data-sync foreground service type
- [ ] Covered at the app's mirror seam by running the engine headlessly against a stubbed backend and a fake Local Source, asserting on resulting mirror state

## Comments

### Implementer report

**Core engine** — `lib/src/gallery/sync/gallery_sync_engine.dart`: pure Dart, no Flutter, GetX or UI
imports. Drains `GalleryMirror.itemsNeedingUploadRetry()` — wiring ticket 20's retry mechanism to
actually run, having been built there but deliberately never called — then `itemsPendingUpload()` (a
new mirror query: device rows covered by an *active* Sync Pair), up to 3 parallel uploads, with a
prompt `requestPause()`. Progress is written to a new `SyncRunState` table (schema v8→v9) — the
engine's only output, per the spec's "the database is the interface" rule.

**Android platform wiring** — `gallery_data_sync_service_io.dart` and `gallery_sync_task_handler.dart`:
a `flutter_foreground_task`-backed `dataSync` foreground service running the engine in a genuine
headless isolate. `AndroidManifest.xml` gained `FOREGROUND_SERVICE_DATA_SYNC` and the service
declaration. Other platforms get `null` through the same conditional-import seam `local_source.dart`
already uses.

**UI** — `GalleryDataSyncController` polls `syncRunState()` on a timer (it is never called *by* the
engine) and reconciles a stale `running` status left behind by a killed process back to `paused`. A
Backup card (start/pause, progress) was added to the Gallery folders screen.

**Key decision the ticket did not settle:** the headless isolate reconstructs a non-interactive OIDC
token refresh, mirroring `LoginController`'s cold-start path, but deliberately never falls back to the
interactive login flow if the refresh fails — a background service must never pop a browser. It aborts
the run with a clear `SyncRunState.lastError` instead, over a small dedicated WebDAV backend rather
than reusing `FileService`/`LoginController`. (Serialising concurrent refreshes across the two isolates
is ticket 23.)

### Verifier verdict

APPROVED — checked against every acceptance criterion.

- **The "headless" claim is real, not nominal.** `GallerySyncEngine` imports only dart core,
  `gallery_mirror.dart`, `gallery_mirror_database.dart` and `gallery_upload_service.dart`. The isolate
  entrypoint genuinely spawns a second `FlutterEngine` via `flutter_foreground_task` and builds a
  dedicated `_HeadlessWebDavBackend` precisely to avoid `FileService`/`LoginController`, which do carry
  GetX and Flutter.
- **State flows one way**: the engine only writes `SyncRunState`, the UI only polls it, and no callback
  path exists in either direction.
- **Process death recovers**: item-level `uploadState` is written only after an attempt completes, so
  no row is ever stuck mid-flight, and `_reconcileAndStartPolling` corrects a stale `running` row to
  `paused` on restart. Resume never re-offers an already-uploaded item.
- **The refresh is genuinely non-interactive**: `_loadHeadlessSession` calls `refreshToken()` only and
  aborts by returning null; it never reaches `loginAuthorizationCodeFlow` or `url_launcher`.
- **Ticket 20's rules survive the engine's path**: `retryMismatchedUpload` is now actually called, and
  the `assumedMismatch` branch still never deletes.
- Nothing from tickets 23/24/25/26/27 present.

`flutter test` 287/287 (base was 281, no skips or deletions — confirmed by running both revisions),
`flutter build web --release --base-href=/app/` succeeds, `flutter build apk --debug` succeeds and the
built APK's manifest carries `FOREGROUND_SERVICE_DATA_SYNC` and the service component. Verified against
base `7902781`.

### Post-approval fix (foreman-directed)

The verifier noted `onNotificationButtonPressed` was wired while no `notificationButtons` were ever
passed to `startService`/`updateService` — the notification's pause control could never appear, leaving
the handler unreachable. Fixed in `fa1b56e`: `startService` now passes
`NotificationButton(id: pauseSignal, text: 'Pause')`, matching the id the handler switches on. The
plugin's Kotlin `NotificationContent.updateData` leaves a stored button set untouched when a later
`updateService` omits it, so it does not need repeating on every periodic update. **No resume button
was added** — the handler switches on `pauseSignal` only, and a second id would have restructured it
beyond a narrow fix; resume remains an in-app control. `flutter test` 287/287, web release and debug
APK builds both still succeed.

### Follow-up recorded, deliberately not done here

`gallery_upload_backend.dart` still declares `WebDavGalleryUploadBackend` alongside the abstract
interface, so `file_service.dart` and its GetX controllers sit in the engine's *import* graph even
though the headless path never instantiates them. Runtime headlessness is intact; the constraint is
simply no longer expressed by the imports. Splitting the file and adding an import-graph guard test is
queued as separate cleanup.
