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

**Status:** resolved

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

## Comments

### Implementer report

`GalleryMirror.removeSyncPair` now soft-deletes (`SyncPairs.removedAt`) instead of deleting the row —
a removed pair is kept forever as a historical target. Dedup and reconcile (`_upsertLocalItem`,
`applyPage`) check every target a Local Source has ever had (`_allSyncPairs` /
`_allCoveringSyncPairs`), while writes (`expectedUploadTarget`) and `createSyncPair`'s overlap check
see only the active pair (`_activeSyncPairs`, filtered on `removedAt IS NULL`) — the spec's "current
target for writes, all targets for lookups" rule. That is what makes a photo already backed up to an
old target keep reading as Synced after a retarget or a reconcile pass, instead of duplicating or
silently dropping to *Device only*.

Files:

- `lib/src/gallery/mirror/gallery_mirror_database.dart` (+`.g.dart`) — schema v7→v8:
  `SyncPairs.removedAt`, and a table rebuild (`m.alterTable`) dropping the old
  `UNIQUE(local_folder_path)` constraint, since a retargeted folder now legitimately has more than
  one row.
- `lib/src/gallery/mirror/gallery_mirror.dart` — the lookup/write split above.
- `lib/src/gallery/gallery_source_folders_view.dart` — a *Retarget* action beside *Remove*: picks a
  new Seraph folder, states plainly that old photos stay where they are and only new ones go to the
  new target, then does add-folder → remove-pair → create-pair.
- Tests: a new migration test; a new `gallery_sync_pair_retarget_test.dart` (retarget behaviour, a
  wipe-and-reconcile test with a retarget in history asserting Availability stays Synced, and an
  arrival-order variant); two `gallery_sync_pair_test.dart` cases rewritten because ticket 21
  deliberately changes their contract. `flutter test` 281/281 (up from 275),
  `flutter build web --release --base-href=/app/` succeeds.

**Decisions the ticket did not settle:**

1. "Reinstalling the app reconciles" is modelled and tested as wiping the mirror's `GalleryItems`
   cache while the local-only `SyncPairs` configuration survives. A genuine full uninstall that also
   wipes `SyncPairs` would lose historical-target knowledge for a retarget that happened before the
   wipe — an accepted, pre-existing consequence of local-only Sync Pair storage (ticket 18's design),
   not something this ticket can close.
2. "Removing a Sync Pair discards only items not yet uploaded" is vacuous today: there is no persisted
   upload queue yet (tickets 22/25), so nothing needs discarding.
3. The retarget flow changes only the Seraph side, per the spec's own example; the Local Source side
   is unchanged, so no local-folder picker appears in it.

### Verifier verdict

APPROVED — diff checked against every acceptance criterion.

- **Write/lookup split holds with no crossover in either direction:** `expectedUploadTarget` and
  `createSyncPair`'s overlap check use `_activeSyncPairs()` only; `applyPage`, `_upsertLocalItem`,
  `applyLocalScan` and `applyLocalDelta` all use `_allSyncPairs()`.
- **Migration is safe:** the migration test builds a raw-SQL v7 fixture holding a pre-existing row and
  asserts it survives the table rebuild with `removedAt` defaulting to null — a real v7 fixture, not a
  fresh v8 database.
- **The two rewritten ticket-18 tests are a scheduled contract change, not a weakened guarantee.**
  Ticket 18's "removing a Sync Pair returns its items to heuristic dedup" became "removing a Sync Pair
  does *not* return them to the fuzzy `(size, capturedAt)` fallback"; a second test was added showing a
  cloud item arriving at the removed pair's own historical path and size still merges
  deterministically. The two cannot both hold literally, and the code now implements ticket 21's
  version. That is correct: D18 in `docs/gallery-mode-design-notes.md` ("a Sync Pair keeps its
  historical targets; existence checks consult all of them") already existed at the base SHA as a
  documented correction to D2. Ticket 18 shipped before upload existed and could not implement it;
  ticket 21 is the ticket assigned to.
- Nothing from tickets 22/24/25/26/27 present.

`flutter test` 281/281, `flutter build web --release --base-href=/app/` succeeds. Verified against
base `3444edf`.
