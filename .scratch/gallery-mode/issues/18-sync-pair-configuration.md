# 18 — Sync Pair configuration

**What to build:** An Android user maps a folder on their phone to a folder in
Seraph. Everything under the phone folder will be uploaded there, relative path
preserved. More than one Sync Pair can be configured, so the camera folder and
the screenshots folder can go to different places.

A Sync Pair's Seraph folder **automatically becomes a Gallery Source Folder**, so
the user does not configure the same folder twice. Gallery Source Folders remain
independently configurable, so folders nothing uploads to still appear in the
gallery.

**Sync Pairs live in the app's local database**, not on the server: they
reference a Local Source that exists on exactly one device. Losing them to a
data wipe costs a reconfiguration, not data.

**A Local Source may appear in at most one Sync Pair.** Otherwise a photo has two
remote paths and two verification states, and the remote path stops being a pure
function.

**A Sync Pair replaces the merged gallery's dedup heuristic.** Ticket 15 had to
decide, with no Sync Pair to consult, whether a device row and a cloud row are
the same photo, and could only match on `(size, Capture Date)`. That heuristic is
wrong in both directions: burst shots and screenshots collide on both values and
get merged into one item, while a Capture Date the server extracted from EXIF
that disagrees with the device's own value splits one photo into two.

A Sync Pair makes the answer deterministic, because the remote path is a pure
function of `(Sync Pair, relative path)` — the same rule ticket 19 uploads by.
For a device item a Sync Pair covers, the expected remote path is computable
without uploading anything, and dedup becomes an exact match on
`(remote path, size)` against the gallery read model. That is worth doing in
*this* ticket rather than at first upload: a user whose Seraph folder already
holds photos — put there by another client, or by a previous install — sees them
correctly merged as Synced the moment they configure the pair, instead of the
whole folder appearing twice.

Dedup resolves in this order, first match wins:

1. **A remote path recorded against the item** by an actual upload. Introduced in
   ticket 19; nothing records one yet at this ticket, so it is inert here.
2. **The expected remote path derived from a Sync Pair**, matched together with
   size. Deterministic for every device item a pair covers.
3. **The `(size, Capture Date)` heuristic from ticket 15**, and *only* for device
   items no Sync Pair covers. It stays because a user may keep photos in Seraph
   that nothing on this phone uploads, but it is explicitly best-effort and must
   be named as such in the code, not left looking authoritative.

Rule 2 taking precedence over rule 3 is the point: once a pair covers an item,
the heuristic must not get a vote, or a burst-shot collision can still merge two
distinct photos that path matching would have kept apart.

No uploading in this ticket — configuration only.

**Blocked by:** 06, 15

**Status:** resolved

- [ ] A user can create a Sync Pair by picking a device folder and a Seraph folder, using the pickers already in the app
- [ ] Creating a Sync Pair adds its Seraph folder to the user's Gallery Source Folders
- [ ] Multiple Sync Pairs can be configured, targeting different Seraph folders
- [ ] Adding a device folder already covered by another Sync Pair is refused with a clear explanation
- [ ] The pairs list shows what each pair maps to and how many photos it covers
- [ ] Sync Pairs persist across app restarts
- [ ] Sync Pair configuration is expressed against a Local Source, not a hardcoded path, and the UI works entirely above that seam
- [ ] Configuration is unavailable on platforms without a Local Source implementation, rather than present and broken
- [ ] Configuring a Sync Pair whose Seraph folder already holds a device photo's counterpart merges the two into one Synced item, without any upload having happened
- [ ] For a device item covered by a Sync Pair, dedup matches on expected remote path plus size, and the `(size, Capture Date)` heuristic is not consulted at all
- [ ] Two distinct device photos of identical size and Capture Date, both covered by a Sync Pair, stay two items — the case the heuristic merged wrongly
- [ ] A device photo whose device Capture Date disagrees with the Capture Date Seraph extracted still merges into one item when the paths match — the case the heuristic split wrongly
- [ ] The heuristic still applies to device items no Sync Pair covers, and is named in the code as best-effort rather than presented as authoritative
- [ ] Removing a Sync Pair returns its items to heuristic dedup without duplicating or dropping any gallery row
- [ ] Covered at the app's mirror seam with a fake Local Source and a stubbed backend, including the collision and disagreeing-Capture-Date cases above

## Comments

### Implementer report

Implemented in `app/seraph_app`.

**Schema** (`lib/src/gallery/mirror/gallery_mirror_database.dart`, regenerated `.g.dart`): new
local-only `SyncPairs` table (`localFolderPath` unique, `spaceProviderId`, `path`, `createdAt`),
schema v5→v6 with an additive migration, covered by a new migration test in
`gallery_mirror_database_test.dart`.

**Mirror logic** (`lib/src/gallery/mirror/gallery_mirror.dart`): `createSyncPair` / `listSyncPairs` /
`removeSyncPair`, plus a `SyncPair` domain model and `SyncPairConflictException`. Dedup now resolves
in order: (1) existing `(providerId, path)` row, (2) a Sync Pair's deterministic expected-remote-path
match (path + size, Capture Date never consulted) in both `applyPage` (cloud arriving) and
`_upsertLocalItem` (device scan arriving), (3) the ticket-15 `(size, capturedAt)` heuristic — which
now explicitly excludes any device row a Sync Pair covers. Creating a pair retroactively merges
pre-existing device/cloud counterparts (`_mergeExistingCounterparts`) without any upload. Removing a
pair only stops future matching — no row is touched, and the Gallery Source Folder it created is left
alone.

**UI**: new `local_folder_picker_dialog.dart` (lists device folders from
`GalleryMirror.listLocalFolders()`, disabling ones already paired) and a third *Sync Pairs* section on
`gallery_source_folders_view.dart`, gated on Local Source presence like the existing *On this device*
section, wired to add the Seraph folder via `GalleryService.addSourceFolder` then `createSyncPair`.

**Tests**: new `test/gallery/mirror/gallery_sync_pair_test.dart` covers pair CRUD, overlap conflict
(exact/parent/child), persistence across restart, photo counts, and every dedup criterion
(disagreeing Capture Date merging in both arrival orders, burst-shot collision protection in both
arrival orders, uncovered-item heuristic fallback, retroactive merge on creation, no duplication or
drop on removal). Widget tests added to `gallery_source_folders_view_test.dart`. `flutter test`
330/330 and `flutter build web --release --base-href=/app/` both pass.

**Decisions the ticket did not settle:**

1. Android's Local Source identifier is the folder identifier itself (MediaStore `RELATIVE_PATH`,
   e.g. `DCIM/Camera/`) — the same string `LocalFolder.path` already uses — rather than a new
   abstraction.
2. The conflict check refuses *overlap* (equal, parent or child folder), not just an exact match,
   since a parent/child pair would still double-cover files.
3. The device-folder picker is a new minimal dialog mirroring `FolderPickerDialog`'s chrome, since
   none existed; the Seraph side reuses `FolderPickerDialog` unchanged.
4. Following the existing convention in that file, the widget tests do not drive the full nested-dialog
   add flow (it would need a stubbed WebDAV `FileService`, which no existing test there does for the
   cloud-folder-add case either); add-flow correctness is covered at the mirror seam instead.

### Verifier verdict

APPROVED — diff reviewed against every acceptance criterion and against the ticket's invariants
(one Sync Pair per Local Source, remote path a pure function, the Seraph folder becoming a Gallery
Source Folder, Sync Pairs local-only, configuration moving no photos). `flutter test` passes,
`flutter build web --release --base-href=/app/` succeeds, no new lint issues in the changed files.
Verified against base `d696825`.
