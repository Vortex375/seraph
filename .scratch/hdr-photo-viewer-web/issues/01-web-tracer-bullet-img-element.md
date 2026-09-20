# 01 — Web tracer bullet: cloud photos through an `<img>` element

**What to build:** the web counterpart of the Android tracer bullet. A
web photo page embeds a plain `<img>` (via `HtmlElementView`) whose
`src` is a blob URL (`Url.createObjectUrlFromBlob`) of the
already-fetched full-resolution bytes. The gallery photo viewer renders
**cloud** photos through it on `kIsWeb`: the already-loaded thumbnail
(`Image`, from the cache the grid warmed) shows first, the bytes arrive,
the blob URL is created and the element replaces the thumbnail — no
cross-fade. The element is styled `pointer-events: none`, so Flutter
keeps every pointer event: tapping toggles the chrome via the existing
page-level `GestureDetector`, and swiping pages exactly as before. There
is no capability detection (spec: "Detection adds a branch that can
never change an outcome") and no zoom — the image sits fit-contained at
1×. A fetch failure or `<img>` error leaves the thumbnail showing.
Blob URLs are revoked on dispose and on page swap.

Non-web platforms are untouched: the Android native path and the iOS
Flutter rendering stay exactly as shipped. The work should live as a web
branch beside the existing one in the photo page (reusing `HdrPhotoPage`'s
fetch/fallback shape where it fits — extracting more shared structure is
fine, inventing a second fetch pipeline is not).

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] A gallery cloud photo opened full-screen in Chrome on an HDR
      display shows highlight pop for a gain-map photo (the objective
      signal: compare with HDR off in the OS).
- [ ] The page shows the photo's thumbnail until the bytes land, then
      swaps to the `<img>`; never a blank page.
- [ ] Tapping the photo toggles the app bar / immersive mode; the page
      does not lose the tap to the DOM element.
- [ ] Swiping pages photo-by-photo in capture-date order at 1×,
      including through not-yet-loaded pages.
- [ ] Firefox (or Chrome with HDR off) shows the correct SDR base image
      — graceful by design, nothing gated.
- [ ] A fetch failure or `<img>` error leaves the thumbnail showing.
- [ ] Blob URLs are revoked when a page is disposed or swapped (no leak
      across a paging session).
- [ ] Device/browser demo: recorded checklist lines for Chrome-HDR,
      Chrome-SDR, Firefox (see the spec's testing decisions).
