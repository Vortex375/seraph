# 24 — Scheduled background backup with user constraints

**What to build:** **Phase 3 ships here.** Photos back themselves up without the
user thinking about it. A photo taken now starts backing up within seconds; the
historical backlog catches up unattended overnight; and none of it costs mobile
data or a dead battery unless the user said it could.

Scheduled background work is the backbone, not a long-lived foreground service:
Android 15 caps cumulative data-sync foreground runtime at roughly six hours a
day. Periodic work handles unattended catch-up; expedited work fires when the
content observer reports a new photo.

**Constraints are declared to the OS and enforced by it**, not polled by us —
unmetered network, charging, battery-not-low — with the user choosing which
apply.

**Blocked by:** 17, 23

**Status:** resolved

- [ ] Photos back up with the app closed, without the user starting anything
- [ ] A newly taken photo triggers an expedited run and starts uploading within seconds
- [ ] The user can require unmetered network, charging, and a battery threshold, and those choices are honoured
- [ ] With constraints unmet, no upload runs and no battery is spent polling
- [ ] Changing constraints takes effect without reconfiguring the Sync Pair
- [ ] The time of the last successful pass is visible in the app, so silence is distinguishable from success
- [ ] A device rebooted mid-backlog resumes without user intervention
- [ ] Background and foreground runs do not both process the same photo
- [ ] Cumulative foreground runtime stays well inside the platform's daily budget
- [ ] Covered at the app's mirror seam by invoking the engine the way the scheduler does and asserting on resulting state; scheduling registration itself is verified by inspection of what is scheduled, not by waiting on the OS

## Comments

### Implementer report

**Scheduling mechanism (the ticket's open question):** Android WorkManager via the `workmanager`
plugin, not a long-lived foreground service — matching the ticket's own framing that scheduled
background work is the backbone. After the rework round there are three tasks:

- **Periodic** (`registerPeriodicTask`, 6h cadence) — unattended backlog catch-up, full user
  constraints.
- **Content-triggered one-off**, non-expedited, with `contentUriTriggers` on
  `content://media/external/images/media` — a genuine JobScheduler content-URI trigger that fires even
  with the app process fully killed, re-armed after each firing since Android consumes these one-shot.
  Stronger than ticket 17's in-Activity `ContentObserver`, which only works while the process is alive.
- **Expedited fast path**, network constraint only (the sole kind WorkManager permits on expedited
  work), fired directly from ticket 17's in-app content-observer stream through the coordinator.

Both callbacks run `GallerySyncEngine` inside WorkManager's own cold isolate rather than starting
ticket 22's `dataSync` foreground service, avoiding Android 12+'s restriction on starting a foreground
service from the background. Each invocation is a bounded chunk; since `GallerySyncEngine.run()`
rebuilds its queue from mirror state every call, repeated bounded runs drain a large backlog over time.

**Constraints:** three `SettingsController` toggles (unmetered-only, requires-charging,
battery-not-low) mapped straight to WorkManager `Constraints` and enforced by the OS before the
callback ever runs — nothing in the app polls them. `GalleryBackupScheduleCoordinator` re-registers
both OS triggers whenever a Sync Pair changes or a constraint toggles, and cancels everything once no
active Sync Pair remains.

**A run the OS stops mid-flight:** item-level `uploadState` is written only after an attempt completes
(unchanged since ticket 22), so a killed process leaves nothing stuck. Reboot needs no app-side
handling — confirmed in the built debug APK's merged manifest that WorkManager auto-merges
`RECEIVE_BOOT_COMPLETED` and re-arms itself.

**Refactor:** the non-interactive OIDC session and refresh-lock logic moved out of
`gallery_sync_task_handler.dart` into `gallery_headless_sync.dart`, shared by the ticket-22 foreground
service and the scheduler, so ticket 23's rule stays one code path rather than two that could drift.

**Bug caught during implementation:** a first migration attempt using `addColumn` for
`SyncRunState.lastSuccessAt` failed on a multi-version jump (v8→v11), because `SyncRunState` is itself
created mid-ladder at v9 by `createTable`, which already includes every current column. Fixed with
`alterTable`/`TableMigration`, matching ticket 21's precedent for the same situation.

### Verifier verdict (round 1)

REWORK — three defects, all in the scheduling itself. Ticket 23's rule was confirmed intact after the
extraction, the migration fix correct, and no scope creep.

1. **The content trigger never armed on a real device.** `expedited: true` combined with
   `contentUriTriggers` and `requiresCharging`/`requiresBatteryNotLow` is rejected by WorkManager at
   `WorkRequest.Builder.build()` — expedited jobs support only network and storage constraints. Since
   battery-not-low defaults to true, this threw on every fresh install and only the 6-hour periodic run
   survived, so "a newly taken photo starts uploading within seconds" did not hold. The throw was
   unhandled in `reschedule()` and swallowed by a bare `catch (_)` in the re-arm path.
2. **No mutual exclusion between the WorkManager path and the foreground-service path** — the engine
   rebuilds its queue with no per-item claim and nothing consulted `SyncRunState.status` or
   `isRunningService`, so a scheduled firing during a user-initiated backup could upload the same photo
   twice.
3. **The re-arm was not durable:** it happened only if the callback ran to completion, so a killed or
   timed-out isolate lost the content trigger permanently, with no periodic backstop.

### Rework as landed

1. Three tasks as described above: the expedited one carries a network constraint only and is fired
   from the in-app observer; the periodic and content-trigger tasks stay non-expedited and carry the
   user's full constraints.
2. New `SyncRunLock` table (schema v12) using the same atomic-UPSERT lease shape ticket 23 established,
   deliberately kept as its own table so it cannot regress that verified code. It adds self-renewal
   (every 2 minutes against a 5-minute lease) so a run may span hours, and `runHeadlessGallerySync`
   became the single chokepoint both entrypoints route through, returning a `HeadlessSyncAttempt` that
   distinguishes a refused attempt (`lockBusy`) from a real outcome so the loser never touches
   `SyncRunState`.
3. The periodic firing now also re-arms the content trigger (`shouldRearmContentTrigger`), independent
   of whether the previous content-trigger firing survived — a six-hour worst-case backstop. Scheduling
   failures now write to `SyncRunState.lastError` instead of a bare `catch (_)`.

### Verifier verdict (round 2, after rework)

APPROVED — all three defects genuinely fixed.

- `_registerFastPath` is the only `expedited: true` call in the codebase and carries only
  `networkType`, checked against the plugin's own `WorkManagerUtils.kt` constraint mapping, which
  passes `requiresCharging`/`requiresBatteryNotLow`/`contentUriTriggers` straight to the native
  `Constraints.Builder` alongside `setExpedited` — confirming the documented throw was real and is now
  avoided. The periodic and content-trigger tasks carry full user constraints and are never expedited.
- `runHeadlessGallerySync` is the sole place `GallerySyncEngine` is constructed (confirmed by
  codebase-wide grep), guarded by the lease with self-renewal; a refused attempt returns `lockBusy`
  without touching `SyncRunState`; `SyncRunLock` is separate from `TokenRefreshLock`, which is
  untouched.
- The periodic re-arm runs unconditionally, regardless of whether the sync attempt itself threw.
- The widened-visibility helper `shouldRearmContentTrigger` is genuinely exercised across all four
  branches, not merely restated by its tests.
- Ticket 23's rule still holds: the only three `.refreshToken()` call sites all go through
  `refreshTokenWithLock`.
- Migrations to v12 from both v8 and v10 preserve rows without crashing.

`flutter test` 318/318 (295 at base, net-additive, zero deletions and no `skip:`),
`flutter build web --release --base-href=/app/` and `flutter build apk --debug` both succeed. Verified
against base `44775d2`.
