# 09 — Re-resolve Gallery Source Folders on `spaces.changed`

**What to build:** An administrator who re-points a Space at a different File
Provider should find the gallery following it, not silently stuck on the old
physical location.

The gallery service holds resolved physical prefixes for each configured Gallery
Source Folder so it can match incoming file-change events without a resolve per
event. That set is a cache. Subscribe to `spaces.changed` and re-resolve
affected folders, so the cache has an invalidation signal rather than being
correct only by luck.

**Blocked by:** 03, 07

**Status:** claimed

- [ ] Re-pointing a Space at another File Provider makes the gallery consume events for the new physical path and stop consuming them for the old one
- [ ] A Space becoming inaccessible to a user makes their gallery stop returning photos from it
- [ ] Deleting a Space leaves its configured Gallery Source Folders harmlessly unresolvable rather than breaking the whole listing
- [ ] Re-resolution does not require a service restart
- [ ] Events for Spaces no folder references are ignored cheaply
- [ ] Covered at the gallery service's NATS boundary: publish a `spaces.changed` event with a changed resolution, then assert that events at the new physical path are accepted and events at the old one are not
