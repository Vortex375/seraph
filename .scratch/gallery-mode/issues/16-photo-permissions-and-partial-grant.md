# 16 — Photo permissions and partial-grant degraded mode

**What to build:** The app asks for photo access with an explanation of what it
is for, and handles every answer honestly — including the awkward one.

Under Android 14's partial media grant, the user hands over a hand-picked set of
photos rather than the library. The app runs in a **clearly-degraded mode with a
visible warning** rather than blocking. **It must never report completeness it
cannot verify** — under partial access it can only see the photos it was given,
so "everything is backed up" would be a lie. Any summary of backup coverage must
say what it cannot see.

Refusing access entirely leaves the cloud-only gallery fully working; one
declined permission must not disable the feature.

**Blocked by:** 15

**Status:** resolved

- [ ] The permission request is preceded by an explanation of what access is used for
- [ ] With full access, the gallery behaves as in the previous ticket
- [ ] With a partial grant, the app works on the photos it can see and shows a persistent, comprehensible warning that it cannot see the rest
- [ ] Under a partial grant, no summary, badge or message states or implies that everything is backed up
- [ ] Under a partial grant, the user is offered a way to grant full access or to extend the selection
- [ ] With access denied, the cloud-only gallery works fully and the device half is absent rather than broken
- [ ] Changing the grant while the app is running is picked up without requiring a restart
- [ ] Covered at the app's mirror seam by driving the fake Local Source through each grant state and asserting on what the gallery reports about coverage

## Comments

### Implementer report (commit 4cbee28)

An explanation-first photo permission flow and Android 14 partial-grant degraded
mode, on top of ticket 15's Local Source seam.

- `LocalSource` (`local_media_item.dart`) gained
  `LocalPermissionStatus {unsupported, granted, partial, denied}`,
  `permissionStatus()`, `requestPermission()`, `openAppSettings()`; implemented in
  `AndroidLocalSource` and passed through `LocalScanService`.
- `MainActivity.kt` checks/requests `READ_MEDIA_IMAGES` and
  `READ_MEDIA_VISUAL_USER_SELECTED` together — what makes Android 14 offer its
  three-way dialog — resolves via `onRequestPermissionsResult`, and opens app
  settings. `handleFullScan` now accepts partial access too; previously it
  silently returned empty under a partial grant, an actual bug within this
  ticket's scope. `AndroidManifest.xml` declares the new permission.
- `GalleryGridController` tracks `localPermission`, refreshes it every `reload()`,
  and exposes `requestLocalPermission()` / `openLocalPermissionSettings()`.
- `GalleryView` shows an explanation banner before the first request (dismissible)
  and a persistent, non-dismissible warning under a partial grant with "Choose
  more photos" / "Allow full access"; the summary bar states what it cannot see
  under a partial grant. `WidgetsBindingObserver` re-syncs on app resume, so a
  grant changed in system Settings is picked up without a restart.
- Tests: `FakeLocalSource` now drives permission state; new coverage in
  `gallery_grid_controller_test.dart`, `local_scan_service_test.dart`,
  `android_local_source_test.dart` and `gallery_view_test.dart` exercising all
  four grant states at the mirror seam.

`flutter test` 167/167, `flutter analyze` 45 pre-existing issues (none new),
`flutter build web --release` and `flutter build apk --debug` both succeed.

Decisions the ticket did not settle:

1. Re-requesting after a partial grant and "open settings" are offered as two
   separate buttons, because Android's re-request only reopens the selection
   picker — there is no dialog path back to "allow all" once partial is granted.
2. "Denied" is not distinguishable from "never asked" at the OS level, so the
   explanation banner reappears each app launch after a decline rather than being
   silenced. No extra persistence was added for that.

### Verifier verdict

APPROVED — diff checked against every acceptance criterion, including the
governing constraint that no summary or badge implies completeness under a
partial grant, and that the denied path leaves the cloud-only gallery working.
Tests, analyze, web build and Android debug build all run against commit 4cbee28.
