# 20 — Verification through the delta feed

**What to build:** A photo reads as backed up only once Seraph independently
reports holding it — not when the upload's HTTP response said 201. The proof of
a safe backup is Seraph's claim, not the phone's.

Per-item state:

```
pending → uploading → uploaded → verified
```

**Verified means Seraph reported, through the delta feed, a file at the expected
path with the expected length.** Only Verified may be shown to the user as backed
up, and only Verified items may later have their device copy removed. If
verification never arrives the item stays visibly un-backed-up — **failing in
the safe direction**, a false alarm rather than false confidence.

Verification is asynchronous, because indexing and metadata extraction are, so
recently uploaded photos sit in an intermediate state for seconds to minutes.
The UI must show that state as in-progress and never as done.

Verification *contradicting* the upload — a length mismatch — means delete the
remote file and retry. This is the one case where the app deletes something
remotely on its own.

**Blocked by:** 10, 19

**Status:** resolved

- [ ] An uploaded photo becomes Synced only after the delta feed reports it at the expected path with the expected length
- [ ] Between upload and verification the item shows as in progress, never as backed up
- [ ] A photo whose verification never arrives stays visibly un-backed-up indefinitely
- [ ] A feed entry with a length that contradicts the upload causes the remote file to be deleted and the upload retried
- [ ] Verification survives an app restart between upload and feed delivery
- [ ] A photo uploaded under a disambiguated name verifies against the name it actually went to
- [ ] A photo verified once is not re-verified on every subsequent sync
- [ ] No code path marks an item Verified on the basis of the upload response alone
- [ ] Covered at the app's mirror seam by driving upload and the stubbed feed independently, including feed-never-arrives and length-mismatch cases

## Comments

### Implementer report

`GalleryMirror.recordUploaded` no longer flips a device row's `origin` to `both` on upload success.
It records the actual `(providerId, path)` the upload went to plus an `uploadState` marker, leaving
the row `device` — still shown as not-backed-up, with an in-progress badge. Only
`GalleryMirror.applyPage`, when the delta feed reports exactly that path, decides the outcome: a
matching length promotes the row to `both` (Synced/Verified) and clears the pending markers; a
contradicting length flags it for retry. That is the only code path that can flip a row to Verified.

Files:

- `lib/src/gallery/mirror/gallery_mirror_database.dart` (+`.g.dart`) — schema v6→v7:
  `uploadState` / `uploadTargetProviderId` / `uploadTargetPath` columns plus an index, additive
  migration.
- `lib/src/gallery/mirror/gallery_mirror.dart` — `recordUploaded` rewritten; `applyPage` gained the
  verification branch; new `itemsNeedingUploadRetry`.
- `lib/src/gallery/mirror/gallery_upload_service.dart` — `retryMismatchedUpload`.
- `lib/src/gallery/mirror/gallery_upload_backend.dart`, `lib/src/file_browser/file_service.dart` —
  `remove`/`removeFile` (WebDAV delete), the one case the app deletes remotely on its own.
- `lib/src/gallery/gallery_item_display.dart` — `isAwaitingVerification`.
- `lib/src/gallery/gallery_photo_viewer.dart`, `gallery_tile.dart` — hide the upload button and show a
  distinct in-progress badge while awaiting verification.

The retry mechanism exists and is tested but nothing calls it automatically yet — when retries *run*
is tickets 22/24.

**Decision the ticket did not settle (and its rework):** the implementer initially treated the
`alreadyPresent` outcome — ticket 19's "same size, assume it is ours" short-circuit — identically to a
real PUT. The verifier rejected that; see below. The foreman decided the rule: **the remote delete may
only ever touch a file this device actually PUT in this upload.** `uploadState` now carries four
values — `uploaded`/`mismatch` for a real PUT, `assumed`/`assumedMismatch` for the shortcut — and
`retryMismatchedUpload` branches on them: a real-PUT mismatch deletes and retries at the same path; an
assumed-ours mismatch never deletes, and falls back to ticket 19's disambiguated-name upload via
`_retryAsDisambiguated`, leaving the pre-existing file exactly as it was.

### Verifier verdict (round 1)

REWORK — one defect. Criterion: "a feed entry with a length that contradicts the upload causes the
remote file to be deleted and the upload retried", plus the ticket's central invariant that no code
path may act on the upload's own claim. In `gallery_upload_service.dart`, the same-size collision
short-circuit called `recordUploaded` with the same `uploadState` as a real PUT, so nothing downstream
could tell them apart; a contradicting feed length then made `retryMismatchedUpload` delete a path this
device never wrote. A contradicting length is precisely the evidence that the "it is ours" assumption
was wrong — and the code responded by deleting someone else's file. The path had no test coverage
either.

Everything else was approved in that round: `origin` only ever flips to `both` inside feed-driven code;
`recordUploaded` never marks Verified; the three modified ticket-19 tests reflect genuinely changed
behaviour without weakening never-overwrite, the pure path function or the mid-upload-change guarantee;
the suite grew 267→274 with no deletions or `skip:`; no ticket 22/24/25/26/27 material present.

### Verifier verdict (round 2, after rework)

APPROVED — re-verified the whole diff against every acceptance criterion, with the fix traced
specifically: no call path reaches `backend.remove` for a file this device did not PUT itself; the
delta feed remains the only thing that can mark an item Verified; a row left in a mismatch state still
reads honestly as not-backed-up; the suite stands at 275 with no deletions or `skip:`; nothing from the
later tickets was smuggled in. `flutter test` passes and
`flutter build web --release --base-href=/app/` succeeds. Verified against base `42d6b6a`.
