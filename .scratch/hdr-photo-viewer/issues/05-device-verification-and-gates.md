# 05 — Device verification and build gates

**What to build:** the final acceptance pass. The spec's recorded device
checklist is run end-to-end in one coherent device session, and the repo's
mandatory build gates are run against the finished branch. This ticket
produces the evidence that the feature matches the spec — including the
objective HDR signal, since screenshots tonemap to SDR and cannot serve as
proof.

**Blocked by:** 01 — Native photo view live in the gallery viewer (local
photos); 02 — Zoom and pan in the native matrix; 03 — Cloud-only photos
through the native path; 04 — Spike removal.

**Status:** ready-for-human (device session; build gates already run)

## Answer

Build gates against the finished branch (host: Linux, Flutter stable at
`/home/vortex/Development/flutter/flutter`):

- [x] `flutter analyze` — zero issues.
- [x] `flutter test` — 365 tests pass (including the new
      `gallery_photo_viewer_native_test.dart`, 7 tests driving the host
      widget through fake platform channels).
- [x] `flutter build web --release --base-href=/app/` — succeeds.
- [x] `flutter build apk` — succeeds (Android plugin code changed, so the
      APK gate was mandatory).

Device checklist — needs a human with a real device; screenshots tonemap to
SDR, so the objective HDR signal below is the evidence:

- [ ] Gain-map photo renders with visible highlight pop; the Flutter
      rendering (non-HDR path) shows the same photo without pop — the
      comparison the spike relied on.
- [ ] The display's HDR/SDR ratio reads > 1 while the viewer is open and
      returns to 1 after exit (temporary probe; removed afterwards — the
      spike's `hdrSpikeSampleHdrSdrRatio` was deleted with the spike, so
      re-add it temporarily for the measurement).
- [ ] 1× swipe pages; pinch zooms to 4×; zoomed drag pans without paging;
      zoom-out re-enables paging; tap toggles chrome; details sheet opens
      over the photo with its scrim; open-folder/open-file actions work.
- [ ] Cloud-only photo renders (thumbnail held while downloading, then HDR
      render); error state shows for a missing/undecodable photo.
- [ ] Non-gain-map photo renders normally through the native path (no
      regression for ordinary JPEGs).
- [ ] Exiting the viewer restores SDR behaviour and normal screen behaviour
      for the rest of the app.
- [ ] App backgrounded mid-view and resumed comes back correct (colour mode
      and native view survive the lifecycle).
- [ ] Web build of the gallery viewer still works (platform gate holds).

Original checklist below; the automated lines are recorded above.

- [x] `flutter analyze` zero issues; `flutter build web --release
      --base-href=/app/` succeeds; `flutter build apk` succeeds (Android
      plugin code changed, so the APK gate is mandatory).
- [ ] Checklist results recorded in this ticket under an `## Answer` heading
      with the device/OS the run was done on. *(build gates recorded; the
      device session remains)*
