# 21 — Sync Pair lifecycle and reconcile with historical targets

**What to build:** Configuration changes never move, delete or duplicate photos.
Reinstalling the app does not re-upload everything.

- **Removing a Sync Pair stops future uploads and changes nothing else.**
  Already-uploaded photos stay in Seraph, the Seraph folder remains a Gallery
  Source Folder, and only queued-but-not-yet-uploaded items are discarded. Any
  behaviour where deleting a *setting* deletes *photos* is indefensible.
- **Retargeting is delete-pair-plus-create-pair**, stated explicitly in the UI:
  photos already backed up to the old target stay there, new photos go to the
  new one.
- **A Sync Pair keeps its historical targets**, not just its current one. Writes
  go to the current target; existence checks consult all of them. The rule is
  *current target for writes, all targets for lookups*.

**Reconcile is path-plus-size across current and historical targets**, since
there is no content hashing. Without historical targets, a reinstall after a
retarget would look only at the new target, find nothing, and duplicate every
photo — the original claim that local state is "always rebuildable from the
cloud folders" holds only while the configuration that produced it is unchanged.

Cross-device duplicates and server-side folder reorganisation are consequently
not detected and produce extra copies rather than being recognised. Duplicates
waste space but lose nothing, which is the safe direction.

**The merged gallery's dedup follows historical targets too.** Ticket 18 made
gallery dedup an exact match on expected remote path plus size, derived from the
Sync Pair. Once a pair has historical targets, the same *current target for
writes, all targets for lookups* rule governs dedup: a photo backed up to the old
target and still sitting there must keep reading as Synced after a retarget. If
dedup consulted only the current target it would find nothing, fall through, and
show every already-backed-up photo as Device only — telling the user their
library is unprotected when it is not, and inviting them to re-upload the lot.
This is the same lookup as reconcile, over the same set of targets, and the two
should not grow separate notions of what counts as a match.

**Blocked by:** 19

**Status:** ready-for-agent

- [ ] Removing a Sync Pair deletes nothing in Seraph and leaves its folder as a Gallery Source Folder
- [ ] Removing a Sync Pair discards only items not yet uploaded
- [ ] Retargeting leaves photos at the old target and sends only new photos to the new one
- [ ] The UI states plainly what retargeting will and will not do before the user confirms
- [ ] A Sync Pair records its historical targets, and existence checks consult all of them
- [ ] Reinstalling the app reconciles against Seraph and re-uploads nothing that is already there
- [ ] Reinstalling after a retarget also re-uploads nothing, verified explicitly
- [ ] Reconcile matches on path and size, using a bulk query rather than one request per photo
- [ ] A cold reconcile of thousands of photos completes in a small number of paged calls
- [ ] After a retarget, a photo backed up to the old target still reads as Synced in the gallery rather than reverting to Device only
- [ ] Gallery dedup and reconcile resolve a match over the same set of targets, rather than each carrying its own rule
- [ ] Removing a Sync Pair leaves items that matched through it reading as Synced, since the remote copies are still there
- [ ] Covered at the app's mirror seam, including a wipe-and-reconcile test with a retarget in the history, and an assertion on gallery Availability across that retarget
