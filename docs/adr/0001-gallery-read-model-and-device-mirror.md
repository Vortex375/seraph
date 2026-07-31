---
status: accepted
date: 2026-07-31
---

# Gallery data is projected into its own service and mirrored on the device

Gallery Mode needs to page through thousands of photos in capture-date order and
merge them with photos on the phone. Rather than query the File Index directly,
a new `gallery` service maintains its **own read model** of gallery photos —
built by consuming file-change events filtered to the user's Gallery Source
Folders — and the app keeps a **local SQLite mirror** of that read model, synced
through a delta feed, so the merged view is a single indexed query instead of a
merge algorithm over two live cursors.

## Considered options

**Querying `file-indexer` directly.** Fewer moving parts, but the index covers
documents, music and backups too, so every gallery page becomes a filtered sort
over the whole corpus. It also has no capture date — and capture date does not
belong there, since the indexer's job is not photo metadata. Adding it would put
photo semantics behind the indexer's boundary.

**Ordering by modification time instead of capture date.** Rejected because
mtime cannot survive Seraph's upload path (the file-provider protocol has no
`Chtimes` operation and WebDAV treats `getlastmodified` as protected), so cloud
mtime is *upload* time. Restoring a phone and re-uploading photos from 2019
would pile all of them onto today, and the same photo would show one date on the
device and another once its local copy was freed.

**A lazy two-cursor merge on the device instead of a mirror.** No local database
needed, but item counts would be unknown (no date scrubber, no honest
scrollbar), dedup after paging makes pages collapse and the layout shift
mid-scroll, and every scroll would need the network.

## Consequences

- Some file metadata is stored twice, and EXIF must be parsed server-side. The
  same event subscription that builds the read model is where thumbnail
  pre-generation fires, so the extra pass earns its keep.
- The service must expose a change feed with a monotonic sequence and
  **tombstone rows for removals** — a mirror without tombstones silently keeps
  showing photos that no longer exist.
- The app gains its first local database and its first schema-migration story.
  Sync state, the mirror and the UI list are one table, not three.
- Configuration is expressed in space terms (`spaceProviderId` + path) while the
  read model is keyed physically (`providerId` + path), so the read model is
  **shared between users** while each user's gallery is the union of their own
  folders. Access control falls out of resolving each user's folders at query
  time; revoked access simply yields nothing.
- Because the read model caches space resolutions with no invalidation signal,
  `spaces` gains a `spaces.changed` event.
- Events only fire on change, so adding a folder full of already-indexed photos
  requires an explicit backfill via a prefix query against the File Index. The
  read model is therefore idempotent on `(providerId, path)`, since backfill and
  live events race by construction.
