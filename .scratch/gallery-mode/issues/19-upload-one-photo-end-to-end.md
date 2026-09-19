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

**Status:** resolved

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

## Comments

### Implementer report

Built the manual, one-photo upload tracer bullet. A cloud-upload button appears in the full-screen
photo viewer for *Device only* items; pressing it uploads the photo to its Sync Pair's Seraph folder
at the mirrored relative path, over the app's existing WebDAV client, and reports the outcome via
SnackBar.

Files:

- `lib/src/gallery/mirror/gallery_upload_backend.dart` (new) — `GalleryUploadBackend` interface
  (stat/put), `GalleryUploadException`, and `WebDavGalleryUploadBackend` wrapping the existing
  `FileService`.
- `lib/src/gallery/mirror/gallery_upload_service.dart` (new) — orchestrates the
  never-overwrite / disambiguation / mark-synced logic.
- `lib/src/gallery/mirror/gallery_mirror.dart` — `expectedUploadTarget` (reuses ticket 18's Sync Pair
  path function) and `recordUploaded` (records the path actually used, guarded by an identity-matched
  WHERE clause so a concurrent scan finding the file deleted or changed makes the write a no-op).
- `lib/src/file_browser/file_service.dart` — `writeBytes`, the PUT counterpart to the existing
  `stat`/`readDir`.
- `lib/src/gallery/gallery_photo_viewer.dart`, `lib/src/initial_binding.dart` — UI wiring and DI.
- `test/gallery/mirror/gallery_upload_service_test.dart` plus a `FakeGalleryUploadBackend` in
  `gallery_test_support.dart` — mirror-seam coverage: placement, collision/disambiguation, same-size
  short-circuit, interrupted-upload retry, device file changed or deleted mid-upload, read-only Space.

**Decisions the ticket did not settle:**

1. Disambiguation naming is `IMG_0001.jpg` → `IMG_0001 (1).jpg`.
2. A narrow `GalleryUploadBackend` interface was introduced rather than testing through
   `webdav_client`'s Dio adapter directly, per the ticket's own "stubbed backend" wording.
3. Recursive intermediate-folder creation is delegated entirely to `webdav_client`'s `Client.write`
   (which already retries a 409 with `mkdirAll`) rather than re-implemented.
4. An item no Sync Pair covers is a quiet no-op (`noSyncPair` result, nothing queued) — deciding
   upload eligibility belongs to ticket 22.

**Raised out of scope:** `webdav_client`'s `write()` issues an OPTIONS preflight against the target
path before the PUT. The verifier traced this through and cleared it — see below.

### Verifier verdict

APPROVED — diff checked against every acceptance criterion.

- The remote path is `GalleryMirror._expectedRemotePath`, the unchanged pure function of Sync Pair
  plus relative path; no date-derived layout was introduced.
- Never-overwrite holds: stat the target, upload if absent, `(n)`-suffix disambiguation on a
  different-size collision, no PUT and mark *Synced* on a same-size collision — the ticket's accepted
  false positive.
- `recordUploaded` flips origin `device`→`both` and stores the path actually used, conditioned on the
  row's local identity still matching, so a device row deleted or changed mid-upload is left unmarked.
- No client-side staging: one `put()` to the final candidate path; the pre-existing server-side
  `api-gateway/webdav/atomic_put.go` covers interruption safety.
- Nothing from tickets 22/24/25 was smuggled in — the diff carries only doc-comment references to
  them, no scheduling, timer, queue or retry implementation.
- **OPTIONS preflight cleared:** Seraph's `golang.org/x/net/webdav` `handleOptions` returns an
  unconditional 200 with the default `Allow` header even when `FileSystem.Stat` errors on a
  nonexistent path, and `withAtomicPut` intercepts only `PUT`. Not a defect.
- **Test-count check:** base `d4741fb` already ran 257 tests; HEAD runs 267, exactly the +10 of the
  new file, with no deletions and no `skip:` added. (The "330" in ticket 18's report was a
  miscount, not a shrinking suite — 229 at the end of phase 2 → 257 after ticket 18 is consistent.)

`flutter test` 267/267, `flutter analyze` no new issues, `flutter build web --release --base-href=/app/`
succeeds. Verified against base `d4741fb`.
