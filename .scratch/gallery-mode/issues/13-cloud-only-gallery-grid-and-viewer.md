# 13 — Cloud-only chronological grid and viewer

**What to build:** **Phase 1 ships here.** Opening Gallery Mode shows the user's
photos in Seraph as a grid of Thumbnails ordered by Capture Date, newest first,
scrolling back through the whole collection. Tapping one opens it full screen.
This works on every platform — Android, iOS, desktop and web — with every item
*Cloud only* and no upload anywhere in sight.

The gallery view is a 22-line stub today; this replaces it. Thumbnails come from
the existing preview endpoint and full-resolution images from the existing
download endpoint, using the Space paths the gallery API returns — no new
media-serving endpoint is introduced.

Upload and device-related controls are hidden rather than shown broken, since
nothing on this platform can perform them yet.

**Blocked by:** 12

**Status:** ready-for-agent

- [ ] Opening Gallery Mode shows a Thumbnail grid ordered by Capture Date, newest first
- [ ] Scrolling back through thousands of photos stays smooth and does not stall on the network
- [ ] Scroll position and item count stay stable as more items load — the grid does not shift under the user's thumb
- [ ] Date headings show roughly where in history the user is
- [ ] A scrubber allows jumping to a point in time
- [ ] Tapping a photo opens it full screen; swiping moves through photos in the same order as the grid
- [ ] A photo recorded as unsupported shows a placeholder with the reason rather than being hidden or shown broken
- [ ] Photos display in their correct rotation
- [ ] A photo's details show which Seraph folder it lives in
- [ ] With no network, the gallery still opens and shows already-cached Thumbnails
- [ ] The view opens quickly on first launch after an update
- [ ] The same view works on iOS, desktop and web, with upload controls absent
- [ ] Gallery logic is verified at the mirror seam, not in widget tests; widget tests assert rendering against a pre-populated mirror
