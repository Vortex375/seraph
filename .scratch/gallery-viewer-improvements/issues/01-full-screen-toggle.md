# 01 — Full-screen toggle

**What to build:** Tapping a photo in the gallery full-size viewer hides the app
bar and the system status/navigation bars, leaving only the photo. Tapping
again brings the chrome back. Leaving the viewer (back, or navigating away)
always restores the system UI so the rest of the app is never stranded in
immersive mode.

This mirrors the file viewer's existing `toggleUiVisible` behaviour: a tap on
the photo flips `SystemChrome.setEnabledSystemUIMode` between `immersive` (UI
hidden) and `edgeToEdge` (UI shown). The gallery viewer's app bar (date title,
upload action, details action) renders unchanged when visible and is removed
entirely when hidden, with `extendBodyBehindAppBar` letting the photo fill the
top of the screen.

**Blocked by:** None — can start immediately.

**Status:** resolved

Base SHA: 7242e18f0fe31f23bb0329ebcfb1d8a9a0c2ee99

## Comments

### Implementer report
Committed. Flutter SDK is absent on this machine, so `flutter analyze`/`flutter test` could not be run here; the build gate is unverified in this environment.
What was built (ticket 01 only):
- `_GalleryPhotoViewerViewState`: added `_isUiVisible` `ValueNotifier<bool>`, `_toggleUi()` (flips flag + `SystemChrome.setEnabledSystemUIMode` immersive/edgeToEdge), and a `dispose()` restore to `edgeToEdge` (a targeted fix the file viewer lacks).
- `build()`: wrapped the `Scaffold` in a `ValueListenableBuilder<bool>`; `appBar` renders unchanged when visible, `null` when hidden, with `extendBodyBehindAppBar` keeping the photo full-bleed.
- `GalleryPhotoPage`: added `onToggleUi` callback and wrapped the `InteractiveViewer`/`Center` tree in `GestureDetector(onTap, opaque)` so taps toggle chrome without claiming scale gestures.
- Test: extended `gallery_view_test.dart` with a toggle test using a `SystemChannels.platform` mock handler; asserts AppBar disappears/reappears, `setSystemUIMode` was called, and the two modes differ.
Decisions the ticket didn't settle:
- Wrapped the whole `Scaffold` in the `ValueListenableBuilder` (matching the file viewer's `Obx`-rebuilds-Scaffold pattern) rather than gating `appBar` inline, so the `PreferredSizeWidget` typing stays clean.
- Per spec, only the `InteractiveViewer`/`Center` branch gets the `GestureDetector`; the unsupported/device-only placeholders do not toggle on tap.
- Kept the platform mock installed through viewer `dispose()` (cleared in suite `tearDown`) to avoid an unhandled `MissingPluginException` from dispose's restore call.

### Verifier verdict (REWORK round)
The first APPROVED was a static-only review (no Flutter SDK); running `flutter analyze` retroactively caught two real compile errors (`setMockMethodCallHandler` passed `SystemChannels.platform.name` String instead of the `MethodChannel`). Fixed in a follow-up commit: passed `SystemChannels.platform` directly, and corrected the runtime mock to match the real channel method `setEnabledSystemUIMode` with a plain-String mode argument. `flutter analyze` clean; `flutter test` — all 28 tests pass.

### Final verdict
APPROVED — all six acceptance criteria satisfied with the toolchain running. Non-blocking nit: a `dart format` regression in the swipe test (collapses `(tester) async {` and `await setUpGallery(...)` onto one line at `gallery_view_test.dart:188`) that `flutter analyze` does not flag.

- [ ] `_GalleryPhotoViewerViewState` holds a `ValueNotifier<bool>` for UI
      visibility and a `_toggleUi` method that flips it and calls
      `SystemChrome.setEnabledSystemUIMode` (`immersive` when hiding,
      `edgeToEdge` when showing).
- [ ] `dispose` restores `SystemUiMode.edgeToEdge` so leaving the viewer never
      strands the app in immersive mode.
- [ ] The `Scaffold`'s `appBar` is gated on the visibility flag: the existing
      `AppBar` renders when visible, `null` when hidden; `extendBodyBehindAppBar`
      keeps the photo full-bleed.
- [ ] `GalleryPhotoPage` gains an `onToggleUi` callback and its
      `InteractiveViewer`/`Center` tree is wrapped in a
      `GestureDetector(onTap: onToggleUi, behavior: HitTestBehavior.opaque)`
      so a tap anywhere on the photo toggles the chrome. Pinch-to-zoom still
      reaches the `InteractiveViewer` (tap does not claim scale gestures).
- [ ] Widget test: tapping the photo hides the `AppBar` and sets the system-UI
      mode to `immersive` (asserted via a `SystemChannels.platform` mock
      handler); tapping again brings the `AppBar` back and sets the mode to
      `edgeToEdge`.
- [ ] `flutter analyze` and `flutter test` pass.
