# 26 — Free up space via the Android trash

**What to build:** A user with a full phone can reclaim space by removing device
copies of photos Seraph already holds, without ever risking a photo's only copy.

**Only Verified items may be offered** — items Seraph has independently reported
back, not items the phone believes it uploaded. This is the whole point of
verification and must be enforced, not merely respected by the UI.

**Use the Android trash request, not the delete request.** Trashed photos stay
recoverable for thirty days, turning a mistake into an inconvenience. It is the
same single system dialog and accepts a batch, so it costs nothing.

Afterwards the mirror marks the items *Cloud only*. They stay in the gallery,
viewable at full resolution on demand — freeing space shrinks storage, not the
gallery.

**Accepted risk, worth knowing about:** an item that is Cloud only and is then
deleted from Seraph by other means is simply gone, and the device cannot notice.
That is the deferred remote-deletion tombstone gap seen from the other side.

**Blocked by:** 20

**Status:** ready-for-agent

- [ ] A free-up-space flow offers only Verified items
- [ ] The amount of space to be reclaimed is shown before the user confirms
- [ ] Confirming trashes the device copies in one batch through a single system dialog
- [ ] Trashed photos remain recoverable through the system trash
- [ ] Freed items become Cloud only in the gallery and are not re-downloaded
- [ ] A Cloud only photo can still be opened at full resolution on demand
- [ ] Cancelling the system dialog leaves everything unchanged
- [ ] An item that is not Verified cannot be freed through any path, including a stale UI acting on old state
- [ ] Restoring a freed photo from the trash returns it to Synced rather than producing a duplicate item
- [ ] Covered at the app's mirror seam with a fake Local Source, including an explicit attempt to free a non-Verified item
