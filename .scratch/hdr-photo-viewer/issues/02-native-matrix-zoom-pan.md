# 02 — Zoom and pan in the native matrix

**What to build:** the photo becomes zoomable again — but the transform lives
in the native `ImageView`'s matrix, never on the platform view. Pinch zooms
to a 4× maximum (matching the current viewer's limit), clamped pan once
zoomed, and the native view claims drag gestures only while scaled past 1× so
a horizontal drag at 1× still pages. The native view reports zoom
entered/exited to Dart; the viewer gates its pager's scroll physics on that
report — the same `isZoomedIn` shape the viewer has today — so zooming out
immediately re-enables swiping. No double-tap zoom, no fling momentum: parity
only.

**Blocked by:** 01 — Native photo view live in the gallery viewer (local
photos).

**Status:** implemented (device demo pending human run)

- [x] Pinch zooms the photo smoothly up to 4× and back below 1× clamps to
      fit-center. *(native matrix; device feel pending the demo below)*
- [x] While zoomed, drag pans the photo with clamping (the photo cannot be
      dragged fully off-screen) and the pager does not page. *(clamped in the
      native transform; physics gated on the zoom report, widget-tested)*
- [x] At 1×, a horizontal drag pages to the next/previous photo exactly as
      before. *(widget-tested)*
- [x] Zooming back out to 1× re-enables paging immediately — the pager is
      never stuck after a zoom gesture. *(widget-tested)*
- [x] The zoom-state report from the native view is the only thing gating
      pager physics — no Flutter-side transform is applied to the platform
      view at any point. *(the surface passes an empty gestureRecognizers
      set: a gesture reaches the platform view only when no Flutter
      recognizer claims it, which is the whole split)*
- [x] Widget tests drive the fake channel's zoom-changed reports and assert
      the pager's physics gating follows them.
- [ ] Device demo: pinch-zoom a photo, pan, page away at 1×, and confirm the
      transition zoom→pan→page→zoom-out is fluid.
