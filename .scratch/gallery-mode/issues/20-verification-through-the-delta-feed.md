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

**Status:** claimed

- [ ] An uploaded photo becomes Synced only after the delta feed reports it at the expected path with the expected length
- [ ] Between upload and verification the item shows as in progress, never as backed up
- [ ] A photo whose verification never arrives stays visibly un-backed-up indefinitely
- [ ] A feed entry with a length that contradicts the upload causes the remote file to be deleted and the upload retried
- [ ] Verification survives an app restart between upload and feed delivery
- [ ] A photo uploaded under a disambiguated name verifies against the name it actually went to
- [ ] A photo verified once is not re-verified on every subsequent sync
- [ ] No code path marks an item Verified on the basis of the upload response alone
- [ ] Covered at the app's mirror seam by driving upload and the stubbed feed independently, including feed-never-arrives and length-mismatch cases
