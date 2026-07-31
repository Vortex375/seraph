# 14 — Rescan folder

**What to build:** A user who knows Seraph's index is behind reality — photos
copied in over SMB that never showed up, say — can force a real re-scan of a
Gallery Source Folder themselves, without needing an administrator.

Backfill reads the File Index, which is fast and cheap but inherits whatever
staleness the index has. Index staleness is a pre-existing property of Seraph;
Gallery Mode neither fixes it nor pretends it away, so it offers an explicit way
out. This action triggers a genuine File Provider re-scan, unlike adding a
folder.

**Blocked by:** 08

**Status:** ready-for-agent

- [ ] A "Rescan folder" action is available per Gallery Source Folder in the app
- [ ] Triggering it causes a real File Provider re-scan of that folder, not just a re-read of the index
- [ ] Photos present on disk but missing from the index appear in the gallery afterwards
- [ ] The user gets feedback that a rescan is running and that it has finished
- [ ] Rescanning a folder that is already up to date changes nothing and produces no duplicates
- [ ] Triggering a rescan twice in quick succession does not run two scans over the same folder
- [ ] A rescan of a large folder does not block gallery queries
- [ ] Covered at the gallery service's NATS boundary
