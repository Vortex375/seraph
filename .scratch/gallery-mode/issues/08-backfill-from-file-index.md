# 08 — Backfill a newly added folder from the File Index

**What to build:** Adding a Gallery Source Folder full of photos that Seraph
already holds fills the gallery with them, not just with photos added from now
on. Adding the folder stays instant and costs no filesystem I/O.

File-change events only fire on change, so a folder of already-indexed photos
would otherwise stay invisible forever. Backfill by issuing the paged prefix
query to the File Index for everything under the folder's resolved
`(providerId, path)`, and feed the results through the same read-model path that
live events use.

**Backfill and live events race by construction** — a folder being backfilled
while photos upload into it will see the same file arrive by both routes — which
is why the read model is upserted rather than inserted. This ticket must
demonstrate that property rather than assume it.

Backfill must not turn a configuration change into a heavyweight server job: it
reads the index, never the File Provider.

**Blocked by:** 04, 07

**Status:** ready-for-agent

- [ ] Adding a folder containing already-indexed photos makes them appear in the gallery
- [ ] The add request returns promptly; backfill proceeds in the background
- [ ] Backfill reads the File Index through its published interface and touches no File Provider
- [ ] A file arriving by both backfill and a live event produces exactly one gallery item
- [ ] Backfill interrupted by a restart resumes or restarts without producing duplicates
- [ ] Adding a folder nested inside an already-configured folder does not double its photos in the listing
- [ ] Backfill of a large folder does not block the service from serving queries or consuming live events
- [ ] Covered at the gallery service's NATS boundary with a stubbed File Index responder, including an explicit test that interleaves backfill pages with live events for the same files
