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

**Status:** ready-for-agent

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
