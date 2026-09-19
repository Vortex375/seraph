# 03 — Cloud-only photos through the native path

**What to build:** photos that exist only in the cloud render with HDR too.
The page fetches full-resolution bytes over the existing authenticated loader
(bearer token attached, with its reactive 401/403 force-refresh-and-retry) and
feeds them to the same host widget local photos use — no new auth work, only
a new consumer. The thumbnail-first load sequence already built in ticket 01
is what makes slow downloads acceptable. Failure behaves like today: a
download error or decode error shows the existing error state; a synced photo
whose device copy fails falls back to the cloud stack as before. Paging away
mid-download abandons the fetch cleanly; paging back re-fetches (full-res is
deliberately not cached) and again shows the thumbnail first.

**Blocked by:** 01 — Native photo view live in the gallery viewer (local
photos). Deliberately independent of 02.

**Status:** implemented (device demo pending human run)

- [x] A cloud-only gallery photo opens full-screen and renders through the
      native platform view with HDR highlight pop when it carries a gain map.
      *(same host widget, same bytes flow; pop needs the device demo below)*
- [x] While the full-resolution bytes download, the page shows the photo's
      thumbnail and is never blank. *(widget-tested)*
- [x] A photo whose download fails shows the existing error state; the
      viewer keeps working and other pages still render. *(widget-tested)*
- [x] An expired token mid-session (401/403 on the full-resolution fetch)
      recovers and retries instead of erroring. *(the page consumes
      `GalleryImageLoader.fullResolution`, whose reactive refresh-and-retry
      is already covered by the existing token-recovery tests)*
- [x] Paging away mid-download does not leak the fetch or fight the arriving
      page; paging back re-fetches and again goes thumbnail-first. *(the
      page state ignores late completions after dispose; full-res is never
      cached, so a return re-fetches)*
- [x] A synced photo whose device copy cannot be loaded falls back to the
      cloud rendering exactly as it does today. *(the failure mapping
      reproduces the old fallback states)*
- [x] Widget tests drive the fake channel/loader seams: bytes-then-swap
      sequence, error state on fetch failure, thumbnail shown while loading.
- [ ] Device demo: with a cloud-only Ultra HDR photo (token freshly expired
      beforehand), open it, watch the thumbnail hold, then the HDR render
      land.
