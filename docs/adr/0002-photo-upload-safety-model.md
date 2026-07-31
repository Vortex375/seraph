---
status: accepted
date: 2026-07-31
amended: 2026-08-01
---

# Photo upload is one-way, atomically published, and verified through the feed

Photo backup must never lose a photo, so Gallery Mode uploads in one direction
only and never propagates deletions; a photo's final path never holds a partial
file, because the WebDAV layer stages every PUT and moves it into place; and a
photo counts as backed up only once Seraph **independently reports it back**
through the delta feed — not when the upload's HTTP response says 201. Content
hashes are deliberately *not* used: regular file uploads in Seraph are not
hash-verified either, and Gallery Mode should not invent a stricter standard of
its own.

Atomic publication is a property the **server** provides, so the app uploads
straight to the final path — see [Amendment](#amendment-2026-08-01).

## Considered options

**Propagating deletions.** Rejected outright: the cloud copy is a backup, and a
server bug or a mis-resolved space path could then destroy the user's only copy.
Users instead get an explicit **Erase** action that removes both copies at once,
behind a clear warning.

**Trusting the upload response.** Rejected because it is not evidence about what
Seraph holds. `x/net/webdav`'s `handlePut` opened the destination with
`O_CREATE|O_TRUNC` and copied the request body straight into it, with no
rollback on failure — so an interrupted upload left a truncated file at the
destination, and the client could not tell that case apart from "nothing was
written". Staging plus a move makes the final path either absent or complete;
the feed then confirms it. (That truncation bug was real well beyond Gallery
Mode, and fixing it server-side is what made client-side staging unnecessary.)

**Overwriting on collision.** Rejected. If something already occupies the target
path with a different size, the upload publishes under a disambiguated name. The
same rule means an in-place edit becomes a *new* Gallery Item and both versions
are kept — storage is cheap, and the alternatives either destroy the original or
report `Synced` for bytes that do not match the phone.

**Verifying content with a hash.** `imoHash` is already computed for every
indexed file, but it is a sampled hash, and a Dart reimplementation that
disagreed in any edge case would leave photos stuck short of Verified forever,
silently. SHA-256 during upload streaming was the unambiguous alternative, at
the cost of full-file reads server-side. Both were rejected in favour of
consistency with Seraph's ordinary upload path.

## Consequences

- **Verified** means "Seraph reports a file at the expected path with the
  expected length". Server-side atomic publish already prevents truncation from
  masquerading as completeness; what remains undetected is in-transit
  corruption, which TCP and TLS make rare.
- Only Verified photos may have their device copy removed, and freeing space
  uses the Android trash rather than deletion, so mistakes stay recoverable for
  30 days.
- Verification is asynchronous, so recently uploaded photos sit in an
  intermediate state for seconds to minutes. If verification never arrives the
  photo stays visibly un-backed-up — failing in the safe direction.
- Reconcile after a reinstall matches on path and size, so a Sync Pair must
  remember its **historical targets** and each item must record the path it
  actually went to. Otherwise retargeting a pair would make every photo look
  unsynced and duplicate all of them.
- Cross-device duplicates and server-side folder reorganisation are no longer
  detected, and produce extra copies rather than being recognised. Duplicates
  waste space but lose nothing.
- Erase deletes remotely first and then trashes locally, so a cancelled dialog
  or a restore from trash would otherwise re-upload the photo and silently undo
  the erase. A local **erase tombstone** prevents that. Detecting deletions made
  elsewhere — for example through the web UI — remains unsolved, and such a
  photo will be re-uploaded.

## Amendment 2026-08-01

**Client-side staging is dropped. The app PUTs directly to the final path.**

As originally written, this ADR had the app upload to a temp name in a staging
folder and `MOVE` it into place, on the reasoning above: an interrupted PUT left
a truncated file at the destination, which the never-overwrite rule would then
mistake for a real file, producing a corrupt copy *and* a duplicate.

Between this ADR being accepted and Gallery Mode being specified, that failure
was fixed at its source. The WebDAV layer now stages **every** PUT itself and
moves it into place on completion, so the final path is either absent or
complete for every client — rclone, Nextcloud clients, the web UI and the app
alike. Client-side staging would now be a second implementation of a guarantee
the server already makes, at the cost of an extra round trip per photo and a
staging folder that has to be swept.

What this does **not** change, and what the ADR is mostly about:

- Upload stays one-way, with no deletion propagation.
- The never-overwrite rule and disambiguation on collision are untouched.
- **Verified** still means the delta feed reported a file at the expected path
  with the expected length. The upload response is still not evidence.
- No content hashing.

The reasoning above is kept rather than rewritten, because the argument for
atomic publication is exactly what justified fixing it server-side. Only the
question of *which side stages* was settled differently.
