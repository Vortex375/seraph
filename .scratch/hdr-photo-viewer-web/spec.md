# HDR gallery/file photos on web

Status: ready-for-agent

Phase: implementation planning done — tracer-bullet tickets ready. The
Android native path (`.scratch/hdr-photo-viewer/spec.md`, shipped) left
web explicitly postponed: "iOS and web keep the existing Flutter
rendering". This document is the PRD for closing that gap on web.

## Problem statement

Ultra HDR JPEGs served by Seraph render SDR-only in the web app. The
pixels already arrive with their gain map — the browser throws it away
because Flutter web draws into an 8-bit sRGB canvas, the same structural
limitation Android had. And the same escape hatch exists: on web, the
stack that *can* render the gain map is the browser's own image
pipeline. Hand it a plain `<img>` and it renders HDR on capable
browsers, SDR otherwise.

## Browser support (2026-09)

- **HDR:** Chrome, Edge, Brave, Opera, Vivaldi, Arc (gain-map JPEG,
  ISO 21496-1 + Ultra HDR signaling); Safari 26 (macOS Tahoe / iOS 26+).
  HDR AVIF is supported even more widely, but our files are JPEG.
- **SDR fallback:** Firefox and older Safari render the SDR base layer —
  a correct photograph, by design of the format. No version gate is
  needed on our side; the browser is the gate.
- Preconditions the client controls: HDR display + OS "Use HDR" enabled.
  Known Safari gap: macOS Sequoia renders no HDR photos in web pages at
  all (fixed in Tahoe).

## Implementation decisions

### The `<img>` element is the platform view

Flutter web has `HtmlElementView` — the same escape hatch Android's
platform views are. A web photo page embeds an `<img>` whose `src` is a
blob URL of the already-fetched full-resolution bytes (the same bytes
`fetchFileBytes`/`fullResolution` produce — no second fetch round trip).
The browser decodes, applies the gain map, composites HDR. No Flutter
renderer change, no plugin, no channel.

### Flutter owns gestures; the element gets `pointer-events: none`

On Android, the native view claims gestures and reports state over a
channel, because the gesture arena fight made Flutter-side ownership the
flakiest corner. On web the fight does not exist: with
`pointer-events: none` on the embedded element, every pointer event
falls through to the Flutter canvas and the existing arena runs
unchanged — the `PageView` pages, the page-level `GestureDetector`
toggles chrome, a `ScaleGestureRecognizer` claims pinches. Zoom and pan
are then applied by Flutter as a **CSS transform on the `<img>`**
(translate + scale, `transform-origin` at the pinch focus). This
deliberately inverts the Android rule ("never transform the platform
view"): a DOM CSS transform is composited by the browser, not a Flutter
widget transform over a hybrid view.

### No capability detection

`matchMedia('(dynamic-range: high)')` is advisory and the SDR fallback
is inherent — a false positive shows the base image, a false negative
shows Flutter's SDR rendering. Detection adds a branch that can never
change an outcome, so web always renders through the `<img>` path. One
code path on web.

### Everything else mirrors the Android work

- Thumbnail-first load sequence (already in `HdrPhotoPage`'s shape);
  blob URL created when the bytes land, **revoked** on dispose/page
  swap — the web counterpart of the per-view channel lifecycle.
- 4× maximum zoom, content-clamped pan, `isZoomedIn` physics gating,
  no double-tap zoom, no fling momentum: parity only.
- Fetch failure or `<img>` error → the thumbnail keeps showing (the
  existing "error leaves the thumbnail" state), never a blank page.
- No colour-mode call: the OS owns HDR on web; there is no equivalent
  of `setColorMode` to manage.
- Full-resolution bytes are not cached; paging back re-fetches,
  thumbnail first (the existing deliberate decision).

### Known ceiling

`ponytail:` CSS-transformed `<img>` is rastered by the browser; at 4× a
progressively-rastered image can soften. If that ever visibly matters,
the upgrade path is an HDR canvas (`rec2100-pq` 2D canvas in Chromium)
with the image drawn at full raster scale — deliberately not built now.

## Out of scope

- **iOS/Android native app changes.** The native path ships; nothing
  here touches it.
- **HDR canvas / WebGPU re-rendering.** Only if the CSS-transform
  ceiling bites (above).
- **HDR video.** media_kit owns that pipeline.
- **Per-photo zoom memory, double-tap zoom, gesture changes** beyond
  parity.

## Testing decisions

- **The browser is the device** — same precedent as the Kotlin side,
  which is device-gated with no automation. `flutter test` runs on the
  VM and cannot execute `HtmlElementView`; the web-specific interop
  (blob lifecycle, CSS transform, `<img>` error event) is verified by a
  recorded browser checklist: Chrome with HDR on (highlights pop), HDR
  off (correct SDR), Firefox (correct SDR base), Safari 26 where
  available; paging, tap, pinch, pan on each.
- The shared fetch/fallback logic is already covered by the existing
  fake-channel tests through `HdrPhotoPage`'s seam.
- Gates: `flutter analyze` zero issues; `flutter test`; `flutter build
  web --release --base-href=/app/`.
