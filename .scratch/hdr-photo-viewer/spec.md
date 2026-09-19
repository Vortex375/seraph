# HDR gallery photo viewer

Status: ready-for-agent

Phase: implementation. The spike is done and decided (see "Spike outcome and
traps" under Implementation Decisions). This document is the PRD for the real
feature. The file viewer gets the same treatment in a separate, postponed
effort — its complication is WebDAV-served images rather than this spec's
authenticated gallery loader, and it should not block the gallery.

## Problem Statement

Photos opened in Google Photos look brighter and more saturated than the same
photos opened in Seraph's gallery. The difference is **Ultra HDR**: an
Ultra HDR JPEG carries a monochrome *gain map* beside its base SDR image; on
an HDR-capable display the renderer multiplies the base by the gain map,
pushing highlights above SDR white into the panel's headroom. Midtones and
surrounding UI stay put, which is why it reads as "pop" rather than
"brighter".

Seraph's gallery photo viewer cannot show this, and the reason is structural:

- Flutter on Android draws into an 8-bit sRGB surface. The window-level HDR
  colour mode does not reach it, Impeller's Vulkan backend has no wide-gamut
  image support upstream (flutter/flutter#127852, open, P3), and so every
  image widget decodes only the SDR base layer and silently discards the gain
  map.
- The spike proved a native Android `ImageView`, decoded with `ImageDecoder`
  and hosted as a Classic Hybrid Composition platform view, does render the
  gain map — with `Display.getHdrSdrRatio()` reading 5.0 while it shows, and
  visible highlight pop confirmed by the human on the device.

So the pixels Seraph already downloads and decodes contain HDR information
that it throws away at the last step.

## Solution

On Android, the gallery photo viewer renders **every** photo through a native
platform view wrapping an `ImageView`: decoded with `ImageDecoder` so the gain
map survives, hosted under Classic Hybrid Composition so the window HDR colour
mode applies, with the window's colour mode switched to HDR while the viewer
is open and restored on exit.

The viewer's behaviour does not change for the user:

- Swiping still pages photo-by-photo through the gallery in capture-date
  order, through pages that have not loaded yet.
- Pinch zooms (up to 4×) and, once zoomed, drag pans; at 1× a drag still
  pages. The gestures run on the native view's matrix so the platform view is
  never transformed by Flutter.
- Tapping still toggles the chrome (transparent app bar, immersive mode),
  and the photo-details bottom sheet still opens over the photo and
  composites normally.
- Cloud-only photos and device/local photos look the same and behave the
  same; both fetch full-resolution bytes over their existing paths.
- A photo that is still downloading shows its already-loaded thumbnail; a
  photo that fails shows the existing error state.

On platforms without the native path (web, iOS) the viewer keeps its current
Flutter rendering. This is a platform gate, not a second HDR route — on those
platforms nothing HDR-capable exists on this route (iOS wide-gamut is a
separate question, out of scope).

## User Stories

1. As a gallery user, I want Ultra HDR photos to show their full highlight
   brightness in the photo viewer, so that they look the way they do in
   Google Photos.
2. As a gallery user, I want every photo — not only ones detected as HDR —
   to render through the same viewer path, so that behaviour and look are
   uniform and nothing silently behaves differently per file.
3. As a gallery user, I want pinch-to-zoom and pan on a photo to still work,
   so that I can inspect detail the same way I do today.
4. As a gallery user, I want zoom to stay crisp, so that zooming does not
   resample a stale Flutter snapshot of the photo.
5. As a gallery user, I want a horizontal swipe at 1× to move to the next or
   previous photo, so that paging through the gallery works exactly as
   before.
6. As a gallery user, I want a drag while zoomed to pan the photo rather
   than change pages, so that panning and paging do not fight.
7. As a gallery user, I want the swipe to keep working immediately when I
   zoom back out to 1×, so that paging is never stuck.
8. As a gallery user, I want tapping the photo to toggle the app bar and
   immersive mode, so that I can go full-screen and back as before.
9. As a gallery user, I want the photo-details bottom sheet to open over the
   photo with its scrim, so that I can inspect metadata as before.
10. As a gallery user, I want the "open folder" and "open file" actions from
    the details sheet to work unchanged, so that navigation out of the viewer
    is not affected by the new renderer.
11. As a gallery user with device-only photos, I want the viewer to render
    them with HDR where they carry a gain map, so that local photos get the
    same treatment as anything else.
12. As a gallery user with cloud-only photos, I want the viewer to download
    the full-resolution photo over the authenticated path and render it with
    HDR, so that I do not need a device copy to see photos properly.
13. As a gallery user opening a slow-to-download cloud photo, I want to see
    the photo's thumbnail while the original loads, so that the page is
    never blank.
14. As a gallery user paging quickly, I want the photo I land on to appear
    promptly, so that paging does not feel slower than the current viewer.
15. As a gallery user whose token expired while browsing, I want the
    full-resolution fetch to recover and retry instead of showing an error,
    so that long viewing sessions do not break mid-scroll.
16. As a gallery user opening a missing or undecodable photo, I want the
    viewer to show its existing error state rather than a blank page, so
    that failure is visible and the rest of the viewer keeps working.
17. As a gallery user offline with a synced photo, I want the same
    availability and fallback behaviour as the current viewer, so that the
    new renderer does not change what I can open.
18. As a gallery user, I want exiting the viewer to restore normal screen
    behaviour, so that the rest of the app is unaffected by HDR mode.
19. As a gallery user on a non-HDR Android device, I want photos to render
    correctly (tonemapped or SDR as the device decides), so that the new
    path degrades gracefully rather than breaking.
20. As a gallery user on web, I want the viewer to keep working as it does
    today, so that platforms without Android's native view are not broken by
    this change.
21. As a developer, I want the spike's throwaway harness removed from the
    app, so that no debug-only screens and dead channel methods linger in
    the production code.
22. As a developer, I want the composition mode pinned in the manifest as a
    decided thing, so that nobody re-enables HCPP without re-measuring its
    cost.
23. As a gallery user, I want photos rendered while the app is backgrounded
    mid-view and resumed to come back correct, so that the colour mode and
    the native view survive a normal app lifecycle.
24. As a gallery user, I want the grid, thumbnails, and tiles unchanged, so
    that the HDR treatment is exactly scoped to the full-screen viewer.

## Implementation Decisions

### Composition and renderer

- **Classic Hybrid Composition, one code path.** The platform view is created
  with the expensive/classic init path — never the HCPP init and never the
  texture-layer init — so the real `ImageView` sits in the activity's view
  hierarchy where the window HDR colour mode applies. Every photo the viewer
  shows goes through this path on Android; there is no gain-map probe, no
  per-image routing, no dual renderer.
- **`EnableHcpp` stays `false` in the manifest.** This reverses the
  previously committed `true` and is a decision, not a leftover (see spike
  outcome below).
- **The platform view decodes raw bytes**, delivered as creation params over
  the standard message codec (a Dart `Uint8List` → Kotlin `ByteArray`) — the
  same bytes the fetch layer produced, with no second resolution round trip.
  Decode failure is reported back to Dart, not swallowed.
- **The native view owns its transform.** Fit-center base layout, pinch scale
  to a 4× maximum, clamped pan once scaled — all in the `ImageView`'s matrix,
  mirroring the current viewer's InteractiveViewer limits. The Flutter side
  never applies a matrix transform to the platform view (arbitrary transforms
  on platform views are the flakiest corner and resample instead of
  re-rendering).

### Gestures

- **The native view claims gestures only while zoomed.** At 1× it does not
  intercept drags, so the Flutter `PageView` pages exactly as before; once
  scaled past 1×, the native view consumes drag for panning.
- **The native view reports state to Dart** over a channel: zoom
  entered/exited (the Dart side gates the `PageView`'s scroll physics on it —
  the same `isZoomedIn` shape as today), tap (toggles chrome), and decode
  error.
- **Inbound callbacks use a dedicated channel**, not the shared local-media
  channel: that channel's inbound handler slot is owned by the Local Source's
  change listener, and a second `setMethodCallHandler` on the same channel
  name would steal it. Per-view channel identity (keyed by the platform view
  id) keeps multiple views from cross-talking during a page swipe.
- **No new gestures beyond parity.** No double-tap zoom, no fling momentum on
  the native pan — the current viewer has neither.

### Paging and lifecycle

- **The Flutter `PageView` remains the pager.** Each page hosts the platform
  view for its photo. The pager disposes off-screen pages, so at most the
  current page plus the one mid-swipe neighbour are alive at once; a settled
  state has exactly one platform view.
- **Load sequence per page:** already-loaded thumbnail (Flutter `Image`) is
  shown first — this doubles as the `Hero` child during the grid→viewer
  transition, which a platform view cannot serve as mid-flight — then the
  bytes arrive, the platform view is created and, once ready, replaces the
  thumbnail in the page. The swap happens without cross-fade.
- **Full-resolution bytes are not cached** — paging back to a photo re-fetches
  it (thumbnail first, as above). This matches the existing deliberate
  no-cache decision for full-resolution images.
- **Window colour mode** is switched to HDR when the viewer opens and back to
  default when it closes (including dispose/error paths), via the plugin's
  activity access — the same enter/exit shape the brightness boost already
  uses. No ratio polling, no display listeners in production code; the
  spike's measurement plumbing does not ship.

### Data paths (both already exist)

- **Cloud photos:** the gallery image loader's existing full-resolution fetch
  returns raw authenticated bytes — bearer token attached, with reactive
  401/403 force-refresh-and-retry. It is consumed as bytes today; the only
  change is the consumer.
- **Device/local photos:** the Local Source's existing original-bytes loader
  is the path; unchanged.
- **Fallbacks stay:** device-copy failure falls back to the cloud stack,
  unavailable photos show their existing error state.

### Spike removal

- The spike's debug screen, its settings entry, its route, its one-shot
  channel methods, and its throwaway view type/factory are removed. What
  survives is absorbed into the real implementation (the platform-view
  factory shape, the bytes-as-creation-params flow).

### Spike outcome and traps (2026-09-19)

Recorded so nobody re-derives them; this is the evidence behind the decisions
above.

**The spike succeeded. A native platform view renders Ultra HDR; the feature
is buildable. Decision: ship it on Classic Hybrid Composition.**

Measured on device:

- `Bitmap.hasGainmap()` true on the test photo (genuine Ultra HDR, confirmed
  natively, not by extension).
- `Display.getHdrSdrRatio()` 5.000 while the native view was showing with the
  window in `COLOR_MODE_HDR` (was 1.000 under the Flutter `Image`).
- Classic HC renders the photo with visible highlight pop. HCPP rendered
  blank on this build.
- Visual verdict was given by the human against the device — screenshots
  tonemap HDR to SDR, so no pixel evidence exists beyond the ratio above.

**HCPP: disabled.** Evidence: with HCPP off, zero SurfaceComposerClient
errors across two windows; with it on, continuous per-frame spam starting ~1s
after launch — before the spike screen was even reachable, so app-wide, not
spike-specific. That is removal + timing correlation; the reverse direction
was never confirmed (the re-enable was interrupted). The decision stands
anyway: Classic HC works, is the documented Ultra HDR path, and HCPP showed
nothing while costing the spam. Do not re-enable HCPP for this feature
without re-measuring the spam.

**Traps:**

- A `LIMIT 40` token inside the MediaStore sort order is the pre-Android-11
  trick; Android 11+ validates the sort order strictly and *throws* on it —
  which had surfaced as a quietly "empty library". Cap the scan loop in code
  instead. Same lesson: never swallow the scan exception; the swallowed throw
  is what made the failure look like no HDR photos existing.
- Flutter's image widgets silently drop the gain map. Only a native
  `ImageView` decoded via `ImageDecoder` sees it.
- Platform-view creation params can carry the raw JPEG bytes
  (`StandardMessageCodec` → `ByteArray`) — no second MediaStore round trip
  needed.

**Precedent:** `video_player_hdr` (pub.dev) exists solely to add a
platform-view path to the official video plugin, because the texture path
cannot carry HDR — the platform-view shape is the established way to do this.

## Testing Decisions

- **One seam: the Dart platform-view host widget.** Its interface is bytes
  in; zoom-changed / tap / decode-error callbacks out, plus the window colour
  mode call on viewer enter/exit. Everything externally observable about this
  feature on the Dart side concentrates there. Tests exercise behaviour
  through that interface — never the platform view's internals.
- **Widget tests at the gallery photo viewer level**, driving the host widget
  through a fake platform channel (mock binary messenger), in the existing
  suite's style. Covered: thumbnail shown until the native view reports
  ready, then swapped; zoom-changed gates the pager's physics; tap toggles
  chrome; decode error shows the error state; viewer exit restores the
  colour mode call sequence.
- **Prior art:** the gallery view widget tests and the Local Source's fake
  platform-channel tests are the pattern to follow; the existing
  token-recovery tests show how fetch failure/retry is simulated.
- **The native Kotlin side is device-gated and deliberately not covered by
  automation** — the repo has no on-device/emulator test infrastructure for
  plugins, and the spike set the precedent. Its acceptance is a recorded
  device checklist: gain-map photo renders with pop; `getHdrSdrRatio()` > 1
  while the viewer is open and 1 after exit; 1× swipe pages; pinch zooms and
  pans; zoomed drag does not page; tap toggles chrome; details sheet opens
  over the photo; cloud-only photo renders; non-gain-map photo renders
  normally; exiting the viewer restores SDR behaviour.

## Out of Scope

- **The file viewer.** Postponed to a separate effort; it fetches images over
  WebDAV rather than the gallery loader, and must not block or constrain this
  one.
- **iOS and web.** They keep the existing Flutter rendering. iOS wide-gamut
  (Impeller/Metal) is a separate question.
- **Grid and thumbnails.** Tiles stay SDR; only the full-screen viewer goes
  native.
- **HCPP.** Not revisited here; the manifest decision is recorded above.
- **Per-photo zoom memory, double-tap zoom, gesture changes** beyond parity
  with the current viewer.
- **Videos and non-image media** in the viewer — unchanged.
- **Screenshot fidelity.** Screenshots of HDR content come back tonemapped to
  SDR; a platform limitation, accepted (as in the spike).
- **The brightness boost.** Already ships in the viewer; nothing to do.

## Further Notes

- `minSdk` is 34 — the Ultra HDR floor — so there is no version gate to add.
- The known costs priced in the spike are all addressed by the decisions
  above: zoom/pan in the native matrix (Gestures), Hero via the
  thumbnail-first sequence (Paging), PageView neighbours via the pager's own
  disposal (Paging).
- Under Classic Hybrid Composition the widget tree splits below/above the
  platform view, so the transparent app bar and the details bottom sheet —
  including its scrim — composite on top normally; the HCPP overlay
  limitation that would have threatened this does not apply to this shape.
- Full-resolution bytes ride the channel as a copy per platform-view
  creation; for large photos this is real memory, but it is one photo at a
  time and the spike used exactly this flow.
