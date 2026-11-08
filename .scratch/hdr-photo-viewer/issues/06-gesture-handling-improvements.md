# 06 — Reliable pinch, plus double-tap zoom, in the native HDR viewer

**What to build:** two user-reported gesture fixes for the native HDR photo
viewer (Android; both hosts — the gallery photo viewer and the file viewer —
share `HdrPhotoView`/`HdrPhotoPage`, so both get both fixes):

1. **Pinch-to-zoom is finicky: it often triggers the left/right swipe
   (previous/next photo) instead of zooming.** Root cause (traced through
   the Flutter gesture arena in the pinned SDK): the platform view surface's
   `gestureRecognizers` team currently holds only a `ScaleGestureRecognizer`,
   which accepts a pinch only once the two-finger span changes by
   `kScaleSlop` (18px), the focal point moves `kPanSlop` (36px), or the scale
   ratio passes 1.05. The surrounding `PageView`'s `HorizontalDragGestureRecognizer`
   accepts after a single pointer moves `kTouchSlop` (18px) horizontally —
   which a spreading pinch produces as a side effect, often first. First
   accept wins the arena; when the pager wins, the platform view gets
   nothing and the photo pages instead of zooming. Fix (Dart side): add a
   small custom `OneSequenceGestureRecognizer` ("pinch claim") to the
   surface's recognizer team that accepts the arena the moment a **second
   touch pointer goes down** over the photo. The surface's recognizers form
   a `GestureArenaTeam` with the platform view as captain, so the accept
   resolves BOTH pointers' arenas in the captain's favour (the accept lands
   while the second pointer's arena is still open → eager-winner path), and
   the native view receives the complete two-finger stream. The pager's drag
   recognizer never reaches its 18px slop, so a pinch can never page.
   One-finger swipes are untouched (the claim fires only on a second touch
   pointer), so paging keeps its standard framework slop. This replaces the
   "require a minimum drag distance for the swipe" idea: the pager's drag
   slop is framework-fixed (`kTouchSlop`) and not tunable without replacing
   the `PageView`'s recognizers, and raising it would make paging sluggish
   for everyone. The claim recognizer fixes the root cause — a two-finger
   gesture is claimed before any one-finger drag threshold can fire.
   The existing `ScaleGestureRecognizer` stays in the team: it is still what
   claims live one-finger **pans while zoomed** (focal-point slop, 36px) —
   without it a zoomed pan would only reach the native view at finger-lift
   via arena sweep, jumping instead of tracking.
2. **Double-tap to zoom, and double-tap followed by a vertical drag to
   zoom, do not work at all.** The native view's `GestureDetector` only
   registers `onSingleTapConfirmed`. Fix (native side): **reuse the
   framework's double-tap detection** — `GestureDetector.OnDoubleTapListener`
   (which the existing `SimpleOnGestureListener` already implements) —
   rather than hand-rolling a tap tracker. Verified against the on-disk
   API 34/35 SDK sources (`android/view/GestureDetector.java`), its exact
   semantics are:
   - `onDoubleTap(e)` fires on the **second tap's down** (too early to
     toggle, since the second tap may turn into a drag) — not used for the
     toggle itself.
   - `onDoubleTapEvent(e)` receives the second tap's **down/move/up event
     stream**, with GestureDetector's own scroll detection suppressed while
     the double-tap is in progress — exactly the hook double-tap-drag needs.
   - `onSingleTapConfirmed` is automatically deferred until the double-tap
     timeout elapses (or until up, if the finger is still down), so a
     double-tap never also fires a single-tap — the chrome-toggle
     disambiguation comes free.
   - Double-tap timing/slop (`DOUBLE_TAP_TIMEOUT`, `DOUBLE_TAP_MIN_TIME`,
     double-tap slop, bigger-tap-region tracking) is framework-handled, and a
     second pointer landing mid-tap cancels the tap state (`cancelTaps`).
   What no stock component provides is the **zoom mapping and animation**
   (Google Maps' double-tap-drag is proprietary app code, not an exposed
   API; PhotoView/Subsampling-Scale-Image-View offer double-tap toggle but
   not double-tap-drag; AndroidX Compose's `zoomable` modifier is Compose-only
   and also lacks double-tap-drag). So the custom part shrinks to:
   - `onDoubleTapEvent` wiring in the view (~20 lines): arm on the second
     tap's down (record start scale + focal point), map vertical drag to
     scale while armed (our own `scaledTouchSlop` decides "dragging"), and on
     up, if no drag happened, run the animated toggle.
   - A pure mapping function `doubleTapDragScale(startScale, startY, y,
     viewHeight)` — the drag measured from the tap point (`startY` is the
     second tap's y, never the view centre), Google Maps convention: drag
     down zooms in, drag up zooms out, clamped to [1, MAX_SCALE] —
     unit-tested with plain JUnit (no Robolectric needed; it is the only
     non-trivial logic left).
   - A short `ValueAnimator` (~250ms, decelerate) for the double-tap toggle
     (1× ↔ 2× about the tap point), reusing `zoomTo`'s focal-point math and
     cancelled when a new gesture starts.
   The `ScaleGestureDetector` stays for pinch; pan is suppressed while a
   double-tap-drag is armed. No Dart-side tap changes are needed: taps over
   the live platform view already reach the native view in both hosts (the
   gallery viewer's outer `GestureDetector` only serves the Flutter path and
   the thumbnail phase).

**Blocked by:** None — can start immediately.

**Status:** implemented (device demo pending human run)

- [x] Dart: `PinchClaimGestureRecognizer` (custom `OneSequenceGestureRecognizer`,
      touch-pointer-counting, accepts on the second touch pointer down) added
      to the surface's `gestureRecognizers` in `hdr_photo_view.dart`, next to
      the kept `ScaleGestureRecognizer`; class doc updated to describe the new
      gesture split.
- [x] Dart: widget regression test at the viewer level (fake platform
      channels, `hdrPhotoNativeForTest`): a two-finger horizontal pinch over
      the live platform view does not page AND dispatches `touch` calls to the
      platform view; a one-finger horizontal swipe still pages (existing test
      already covers it); unit tests for the claim recognizer's arena
      behaviour (two touch downs → team captain wins both pointers; single
      touch pointer → no claim; non-touch second pointer → no claim).
- [x] Kotlin: extend the existing `GestureDetector` (`SimpleOnGestureListener`)
      in `HdrPhotoImageView` with `onDoubleTapEvent` (arm/drag/toggle) —
      `onSingleTapConfirmed` unchanged; `ScaleGestureDetector` unchanged for
      pinch; pan suppressed while a double-tap-drag is armed; drag state
      cleared on `ACTION_POINTER_DOWN`/`ACTION_UP`/`ACTION_CANCEL`.
- [x] Kotlin: pure `doubleTapDragScale` companion function (drag measured
      from the tap point; drag down = zoom in, drag up = zoom out — the
      Google Maps convention; clamped [1, MAX_SCALE]); animated double-tap
      toggle via `ValueAnimator` (250ms, decelerate, 1× ↔
      `DOUBLE_TAP_SCALE` = 2× about the tap point), cancelled on a new
      gesture down.
- [x] Kotlin: the plugin gains `src/test/kotlin` +
      `testImplementation 'junit:junit:4.13.2'`; 8 unit tests for
      `doubleTapDragScale` (proportional zoom in on drag down, out on drag
      up, clamps at 1 and MAX_SCALE, identity at zero drag, monotonic,
      degenerate view height, and the drag measured from the tap point rather
      than the view centre).
- [x] Docs: amended `.scratch/hdr-photo-viewer/spec.md` (Gestures section,
      Testing Decisions, and Out of Scope, where "double-tap zoom, gesture
      changes beyond parity" is removed); amended `issues/02`'s "No
      double-tap zoom: parity only" note; extended the device checklist with
      the new gestures.
- [x] Gates: `flutter analyze` zero issues; `flutter test` (gallery suite,
      including `gallery_photo_viewer_native_test.dart`); `flutter build web
      --release --base-href=/app/`; `flutter build apk` (mandatory — `android/`
      is touched); `./gradlew :seraph_local_media:testDebugUnitTest` (8/8).
- [ ] Device demo: pinch with the first finger drifting before the second
      lands still zooms (never pages); double-tap zooms in/out animated about
      the tap point; double-tap + vertical drag zooms continuously measured
      from the tap point — drag DOWN zooms in, drag UP zooms out, the same
      direction whether the double-tap is near the top, centre, or bottom of
      the photo — and does not toggle on release; double-tap-drag up at 1×
      is a no-op; single tap toggles chrome (now after the ~300ms double-tap
      timeout — confirm the latency feels acceptable); zoomed pan and 1×
      paging unchanged.

## Notes and accepted tradeoffs

- A two-finger gesture can no longer page, ever — that is the point; paging
  stays a one-finger gesture with the standard framework slop, matching every
  mainstream photo viewer.
- Single-tap chrome toggle gains up to ~`DOUBLE_TAP_TIMEOUT` (300ms) of
  latency once double-tap detection exists (the framework's disambiguation
  delay). Standard for photo viewers; flagged for the device demo.
- If a one-finger swipe is already in flight (the pager won the arena before
  the second finger lands), adding a finger does not cancel the page — the
  swipe was already committed. Accepted.
- Double-tap-drag uses the Google Maps direction convention (drag down =
  zoom in, drag up = zoom out), measured from the tap point — not the
  photo-viewer convention (drag up = zoom in) and not from the view centre,
  so the direction never depends on where the double-tap happened (the
  user-reported awkwardness this fixes). Double-tap-drag up at 1× is a no-op
  (already at minimum scale); releasing a drag below 1× clamps to fit-center
  and the zoom report re-enables paging.
- The web HDR path (`HdrPhotoPageWeb`) is unchanged; it has its own spec and
  its own "Known ceiling" (no double-tap). Parity there is a possible
  follow-up, not part of this ticket.
- The device demo from issue 02 stays pending; this ticket extends that
  checklist rather than replacing it.
