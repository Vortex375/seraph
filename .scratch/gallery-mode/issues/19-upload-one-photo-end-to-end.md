# 19 — Upload one photo end to end

**What to build:** The user presses a button on a photo and it lands in Seraph,
under the Sync Pair's Seraph folder, at the mirrored relative path. This is the
tracer bullet through the whole upload path; the engine, scheduling and queue
policy come later.

**The remote path is a pure function of `(Sync Pair, relative path)`.**
`DCIM/Camera/2026/IMG_0001.jpg` under `DCIM/Camera → /Photos/Phone` lands at
`/Photos/Phone/2026/IMG_0001.jpg`. A date-derived layout was rejected and must
not be introduced: Capture Date is not a stable property of a file, so the same
photo would map to different remote paths at different times and be uploaded
twice.

**Never overwrite an existing remote file.** If the target path is occupied by
content of a different size, publish under a disambiguated name. If the size
matches, assume it is ours and mark it synced. The only case this gets wrong is
an edit that leaves the file byte-identical in length; that is accepted.

**No content hashing.** Regular file uploads in Seraph are not hash-verified
either, and Gallery Mode does not invent a stricter standard of its own.

**No client-side staging.** Server-side atomic PUT already stages every upload
and moves it into place, so the final path is either absent or complete for
every client. The app PUTs directly to the final path. (ADR 0002 originally
called for client-side staging and was amended on 2026-08-01 to drop it — see
its Amendment section for why.)

**Missing intermediate collections are created on demand** by the client, the
way ordinary WebDAV clients do. General recursive directory creation in the File
Provider layer is a real gap but is out of scope here.

**Record the remote path the photo actually went to**, not a recipe for deriving
it. A later ticket depends on this and recomputing from configuration would
produce wrong answers after a retarget.

**Blocked by:** 18

**Status:** claimed

- [ ] Uploading a photo places it under the Sync Pair's Seraph folder at its mirrored relative path
- [ ] Missing intermediate folders are created, several levels deep if needed
- [ ] An occupied target path holding content of a different size results in an upload under a disambiguated name; nothing is overwritten
- [ ] An occupied target path holding content of the same size results in no upload and the item being marked synced
- [ ] The path the photo actually went to is recorded against the item
- [ ] Uploads go directly to the final path, with no client-side staging folder
- [ ] An upload interrupted by a lost connection leaves no partial file at the final path and can be retried cleanly
- [ ] A photo deleted or modified on the device mid-upload is not marked synced
- [ ] The Seraph copy is byte-identical to the device copy
- [ ] Uploading to a read-only Space fails with a comprehensible reason rather than silently
- [ ] Covered at the app's mirror seam with a stubbed backend, including collision, disambiguation and interruption cases
