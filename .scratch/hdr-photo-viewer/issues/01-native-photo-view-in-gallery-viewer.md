# 01 — Native photo view live in the gallery viewer (local photos)

**What to build:** the tracer bullet. The spike's native view and its factory
are absorbed into production shape — renamed for their real purpose, with a
dedicated per-view callback channel (keyed by the platform view id; never the
shared local-media channel's inbound handler slot) carrying tap and
decode-error reports. A Dart host widget wraps it: photo bytes in as creation
params, callbacks out. The gallery photo page renders **device-local** photos
through this host on Android: the already-loaded thumbnail (Flutter `Image`,
also the `Hero` child) is shown first, then the native view is created and
swaps in once ready — no cross-fade. Tapping the photo still toggles the
chrome and immersive mode. The activity window's colour mode goes to HDR when
the viewer opens and back to default when it closes. At 1× the native view
claims no drags, so swipe paging through the gallery works exactly as before.
Zoom is not in this ticket — the native view sits at fit-center.

Other platforms (web, iOS) keep the existing Flutter rendering — a platform
gate, not a second route.

**Blocked by:** None — can start immediately.

**Status:** implemented (device demo pending human run)

- [x] A gallery photo opened full-screen on Android renders through the
      native platform view; a gain-map photo shows highlight pop on an HDR
      display. *(code complete; pop itself needs the device demo below)*
- [x] The page shows the photo's thumbnail until the native view is ready,
      then swaps to it; the grid→viewer Hero transition still works.
      *(widget-tested; no Hero is wired in the grid today, so nothing to
      preserve there)*
- [x] Tapping the photo toggles the app bar / immersive mode as before; the
      details bottom sheet still opens over the photo with its scrim.
      *(tap report widget-tested; sheet untouched)*
- [x] Swiping pages photo-by-photo in capture-date order at 1×, including
      through not-yet-loaded pages. *(widget-tested)*
- [x] Opening the viewer sets the window colour mode to HDR; exiting (any
      path, including error) restores default. *(widget-tested)*
- [x] A photo that fails to decode natively reports the error over the
      channel and the page shows its existing error state instead of a blank
      view. *(widget-tested)*
- [x] The gallery viewer's behaviour on web is unchanged (existing Flutter
      rendering path still runs there). *(platform gate + web release build)*
- [x] Widget tests at the viewer level drive the host widget through a fake
      platform channel: thumbnail-then-swap, tap toggles chrome, decode error
      shows the error state, colour-mode call sequence on open/exit.
      *(test/gallery/gallery_photo_viewer_native_test.dart)*
- [ ] Device demo: open a local Ultra HDR photo in the gallery viewer and
      page/swipe/tap — recorded checklist lines for render, swipe, tap.
