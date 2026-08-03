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

**Status:** claimed

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
