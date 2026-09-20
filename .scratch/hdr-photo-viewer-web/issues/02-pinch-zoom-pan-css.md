# 02 — Pinch zoom and pan via CSS transform

**What to build:** the web image becomes zoomable — but the transform
lives in the DOM, not in Flutter widgets. A `ScaleGestureRecognizer`
(added at the page level, next to the existing tap detector) claims
pinches; the page applies `translate(...) scale(...)` to the `<img>`
element through `package:web` interop, with `transform-origin` moved to
the pinch focus. Limits mirror the native path: 4× maximum, clamped pan
— an axis pans only once the scaled content exceeds the viewport on that
axis (the same content-rect clamp `HdrPhotoImageView.kt` does, translated
to CSS), a letterboxed axis stays pinned. Zooming back to 1× zeroes the
transform and re-enables paging: the host gates its pager's physics on
the same `isZoomedIn` shape both viewers already have — driven locally
now, no channel needed. No double-tap zoom, no fling momentum: parity
only.

This deliberately inverts the Android rule "never transform the platform
view": on web the CSS transform is composited by the browser (see the
spec's known ceiling for the raster-quality trade-off and its upgrade
path).

**Blocked by:** 01 — Web tracer bullet.

**Status:** implemented (browser checklist pending human run)

- [x] Pinch zooms the photo smoothly up to 4× and back below 1× clamps
      to fit-center. *(code complete; feel needs the browser demo below)*
- [x] While zoomed, drag pans the photo with the content-rect clamp (a
      letterboxed axis cannot be dragged; the photo cannot be dragged
      off-screen) and the pager does not page. *(the clamp mirrors the
      Kotlin view's, aspect read from the loaded `<img>`)*
- [x] At 1×, a horizontal drag pages exactly as before; zooming back out
      re-enables paging immediately. *(one ScaleGestureRecognizer, the
      exact shape InteractiveViewer uses inside these same pagers)*
- [x] The zoom/pan transform is a DOM CSS property on the `<img>` — no
      Flutter widget transform over the page at any point.
- [ ] Device/browser demo: pinch, pan, page away at 1×, confirm the
      zoom→pan→page→zoom-out transition is fluid in Chrome on the HDR
      display.
