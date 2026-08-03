# 29 — Local Folder selection

**What to build:** The user picks which folders on this phone feed Gallery Mode.
Ticket 15 imported the entire media store, so the merged gallery currently
interleaves camera photos with screenshots, WhatsApp downloads, sticker caches,
map tiles and app artwork — the exact pollution that choosing Gallery Source
Folders prevents on the cloud side, arriving through the other half of the view.
This ticket gives the device half the same control the cloud half already has.

**A Local Folder is a filter, not an import boundary.** The full media-store scan
stays unfiltered and the mirror keeps a complete row set; the selection is
applied when the mirror is *read*. That is what makes changing it instant and
reversible, lets the folder list be enumerated from rows already in the mirror
rather than by a second scan or a new platform call, and keeps dedup, local
identity and — in phase 3 — the upload queue and verification reading the whole
device library. **Nothing about which folders a user cares to look at may reach
the answer to "is this photo safe."**

**One rule governs what the filter does:** an unselected Local Folder makes a
row's device copy invisible, and the row then behaves **exactly as though the
device copy did not exist**. A Device only photo in an unselected folder leaves
the gallery. A Synced photo whose device copy sits in an unselected folder
displays, badges and counts as Cloud only. Display, Availability, the
Availability filter and the backed-up counts must all read the result of that one
predicate — not each apply the selection in their own way, which is how they
would come to disagree.

**The selection lives on the device**, beside the Sync Pair configuration to
come, and for the same reason: it names paths that exist on exactly one phone.
It is never sent to the server.

**The default is the camera folders** — `DCIM` and everything beneath it — seeded
**once** on first run, every other folder off. A folder appearing later is off
unless it is under `DCIM`. The seed is a first-run heuristic and must never be
re-derived afterwards: a user who deselects `DCIM/Camera` keeps it deselected.

**One screen, two sections.** Extend the existing Gallery folders screen with
*In Seraph* (what is there today) and *On this device* (this ticket). The device
section is absent entirely where there is no Local Source, rather than present
and empty.

Design record: D21 in `docs/gallery-mode-design-notes.md`. Vocabulary: **Local
Folder** in `CONTEXT.md` — it is not a "Local Source", which is the Sync Pair's
device-side half and the name of the platform seam.

**Blocked by:** 15, 16, 28

**Status:** resolved

- [ ] The Gallery folders screen has an *On this device* section listing the device's photo folders, each with its photo count
- [ ] A folder can be selected and deselected, and the gallery reflects the change immediately without a rescan
- [ ] Only photos in selected Local Folders appear in the merged gallery
- [ ] A deselected folder stays listed and can be selected again
- [ ] On first run the camera folders (`DCIM` and below) are selected and every other folder is not
- [ ] The first-run seed happens exactly once: a user who deselects a camera folder finds it still deselected after a restart
- [ ] A folder that appears on the device after the first run is unselected unless it is under `DCIM`
- [ ] A Device only photo in an unselected folder does not appear in the gallery and is not counted as not-backed-up
- [ ] A Synced photo whose device copy is in an unselected folder appears as Cloud only — in the grid, in its badge, under the Cloud only filter and in the counts
- [ ] The backed-up / not-backed-up summary and the Availability filter agree with what the grid shows, under every selection
- [ ] The full media-store scan is unaffected by the selection: every folder is still scanned, and the mirror still holds rows for unselected folders
- [ ] Dedup and local identity matching still see the whole device library, so deselecting and reselecting a folder produces no duplicate rows and no re-merge
- [ ] The selection is stored on the device and never sent to the server
- [ ] The selection survives an app restart, and the mirror database migrates without losing sync cursors or mirror rows
- [ ] Everything above the Local Source seam stays platform-neutral, and on a platform with no Local Source the screen shows no device section and the gallery behaves exactly as it does today
- [ ] Covered at the app's mirror seam: selection applied to queries, counts and the Availability filter, the first-run seed, and the deselect-then-reselect case

## Comments

### Implementer report (commit 2de1aaf)

Local Folder selection: which folders on this phone feed Gallery Mode.

- `mirror/gallery_mirror_database.dart` (+ regenerated `.g.dart`) — new
  `LocalFolderSelections` table (`folderPath` → `selected`), schema v4 with an
  additive migration; `SyncCursors` and `GalleryItems` untouched, so no user is
  forced into a full gallery re-fetch.
- `mirror/gallery_mirror.dart` — `listLocalFolders()` enumerates folders from
  mirror rows already present (no second scan, no new platform call),
  `setLocalFolderSelected()` records a choice, and one shared
  `_visibilityPredicates` serves `queryPage`, `queryItems`, `totalCount` and
  `availabilitySummary` alike. An unselected folder drops a Device only row
  entirely and demotes a Synced row's *returned* `GalleryItem` to Cloud only
  (origin rewritten, `local*` cleared). Never written back — `applyLocalScan`,
  `applyLocalDelta` and `applyPage` still see the whole device library.
- `gallery_source_folders_view.dart` — an "On this device" section, present only
  where a Local Source exists. Toggling calls `GalleryGridController.reload()`,
  never `syncNow()`, so a change is a mirror re-read rather than a rescan.
- Tests: `test/gallery/mirror/gallery_local_folder_test.dart` as the primary
  seam, a v3→v4 migration test, and widget tests for the new section.

Decision the ticket did not settle: rather than materialising a "seed has run"
marker, the `DCIM` default is **computed** whenever a folder has no
`LocalFolderSelections` row, and a row is written only when the user actually
toggles something. "Seeded once, never re-derived" then falls out for free — an
explicit choice always wins — with no bookkeeping to keep correct.

Unrelated fix needed to keep the suite green: two pre-existing tests in
`gallery_grid_controller_test.dart` began failing intermittently with "can't
reopen a closed database", because the read path's new async hop made a stray
unawaited background page load likely to outlive the test and race `tearDown`'s
`db.close()`. Drained with a trailing `pumpEventQueue()`; no assertions changed.

`flutter test` 229/229, `flutter analyze` clean of new issues (45 pre-existing),
`flutter build web --release` and `flutter build apk --debug` both succeed.

### Verifier verdict

APPROVED — all fifteen acceptance criteria checked against the code rather than
the commit message.

- **Read-path-only filter**: `applyLocalScan`, `applyLocalDelta` and `applyPage`
  are untouched by the diff (confirmed from the hunk headers — the diff starts
  after them). The test "the full media-store scan keeps seeing an unselected
  folder" proves rows for unselected folders survive in the raw table.
- **One predicate, one place**: `_visibilityPredicates`/`_Visibility` is the
  single source used by all four read methods; `_presentedItem` rewrites a
  hidden Synced row to Cloud only for every reader, and
  `GalleryItemDisplay.availability`/`hasLocalCopy` derive from `origin`/`local*`
  alone, so the badge cannot disagree with the counts.
- **No new scan or channel call**: `listLocalFolders` groups
  `GalleryItems.localRelativePath` already in the mirror; `android_local_source.dart`
  gained no new methods.
- **`DCIM` default never overrides a real choice**: a row exists only where the
  user toggled; absence falls back to `_defaultFolderSelected`. Covered by the
  seed test and by a widget test toggling `DCIM` off and confirming it stays off.
- **Migration is additive**: v3→v4 only creates the new table, with a real
  v3-schema fixture confirming existing rows and sync cursors survive.

The `pumpEventQueue()` addition is a legitimate test fix, not a masked defect:
`queryItems`/`queryPage` genuinely await one extra DB read now, adding a real
async hop to the pre-existing `unawaited(_loadPage(...))` pattern in `itemAt`.
The test drains that pending future before the database closes; no production
behaviour is changed or hidden.

Gates run by the verifier: `flutter test` 229/229, `flutter analyze` no new
issues, `flutter build web --release --base-href=/app/` and
`flutter build apk --debug` both succeed.
