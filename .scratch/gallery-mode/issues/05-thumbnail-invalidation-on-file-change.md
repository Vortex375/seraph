# 05 — Remove and invalidate Thumbnails on file-change events

**What to build:** A user who edits a photo in place should see the edited photo
everywhere, and an administrator should not accumulate Thumbnails for files that
no longer exist.

Today a Thumbnail's name is derived from `(providerId, path)` and the target
size, with no modification-time or size component, so editing a photo in place
leaves the old Thumbnail served forever — a staleness bug affecting the whole
product, not just Gallery Mode. Deleted files leave their Thumbnails behind
indefinitely.

Have the thumbnailer subscribe to the durable file-change stream with its own
durable consumer: `deleted` removes the file's Thumbnails, `changed` invalidates
them so the next request regenerates. There is no rename event — a rename
surfaces as delete-at-old plus create-at-new, which is sufficient here.

Note that Thumbnail storage is a flat folder and names embed the dimensions, so
"remove every Thumbnail for this file" currently means attempting each known
size, most returning a not-found. That is acceptable for now; sharding storage
is tracked separately and is not part of this ticket.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] Deleting a file removes its Thumbnails at every size
- [ ] Changing a file in place causes the next preview request to serve a Thumbnail of the new content, not the old one
- [ ] A file that never had Thumbnails produces no errors and no log noise when deleted
- [ ] The consumer is durable, so Thumbnails are still cleaned up for changes that occurred while the thumbnailer was down
- [ ] Redelivery of the same event is harmless
- [ ] Cleanup work does not starve the interactive preview path
- [ ] Covered by extending the existing thumbnailer tests
