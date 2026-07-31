# Gallery Mode — Design Notes

Running protocol of the design conversation for Gallery Mode. Decisions are
recorded with their reasoning and the alternatives rejected, so that a later
reader can tell what was *chosen* from what was merely *assumed*. Terminology
lives in [CONTEXT.md](../CONTEXT.md); this file is the working record.

The two architectural decisions distilled out of it:

- [ADR 0001 — Gallery data is projected into its own service and mirrored on the
  device](adr/0001-gallery-read-model-and-device-mirror.md)
- [ADR 0002 — Photo upload is one-way, atomically published, and verified
  through the feed](adr/0002-photo-upload-safety-model.md)

Status: **specified.** The spec and its implementation tickets live in
`.scratch/gallery-mode/`. One decision below has since changed and one deferred
item has been closed — see [Postscript](#postscript--2026-08-01).

Started 2026-07-26. Design conversation closed 2026-07-31.

---

## Starting point (facts established from the codebase)

- `file-indexer` maintains a Mongo `files` collection fed by `FileInfoEvent` /
  `FileChangedEvent`: `providerId`, `path`, `size`, `modTime`, `mime`, `isDir`,
  and `imoHash` (a *sampled* hash — 16 KB at head/middle/tail plus size).
- `thumbnailer` is strictly pull-based: NATS request/reply on
  `seraph.thumbnail.request`, results cached in a thumbnail file provider under
  a name derived from `hash(providerId + path)` and the target size. Sizes are
  snapped to 128/256/512/1024. Nothing pre-generates thumbnails today.
- `api-gateway` exposes WebDAV (`/dav/p`), `/download/p`, `/preview?p=…&w=&h=`
  and an SSE `/search` that fans out to the indexer over NATS.
- **There is no API that lists "all images under these folders, ordered by
  date, paginated."** WebDAV PROPFIND is per-directory only.
- The Flutter app uses `webdav_client` + Dio + GetX and has **no local
  database**. `lib/src/gallery/gallery_view.dart` is a 22-line stub.
- The file-provider RPC protocol has **no `Chtimes` operation**, and the whole
  file-provider abstraction is pinned to `x/net/webdav`'s 5-method
  `FileSystem` interface (`Mkdir`/`OpenFile`/`RemoveAll`/`Rename`/`Stat`).
- Server-side storage exists only for `spaces`, `shares` and `tokens` — there
  is no per-user preference store.
- Nothing in the codebase reads EXIF.

---

## D1 — One-way upload, no deletion propagation

**Decided.** Sync is upload-only, device → Seraph. Deleting on either side
never affects the other.

Reasoning: the cloud copy is a backup; propagating cloud-side deletions to the
device means a server bug or a mis-resolved space path can destroy the user's
only copy. This also matches the project's stated scope — no general file
sync, photo upload excepted.

**Refinement:** the app additionally offers an explicit **Erase** action that
deletes the device copy *and* the Seraph copy in one go, behind a clear warning
that this destroys the photo completely. This is a deliberate user action, not
automatic propagation.

**Postponed:** *tombstones* for "uploaded, then deleted remotely by other
means — do not re-upload". Without them, a photo deleted from Seraph via the
web UI while the device still holds it will be re-uploaded on the next scan.
Accepted for now; worth revisiting.

## D2 — Layered identity, remote path as the source of truth

**Decided.** "Is this local photo already in Seraph?" is answered by three
mechanisms, layered:

1. **Local sync-state DB** — the fast path. Treated as a cache, never as the
   authority.
2. **Deterministic remote path** — the source of truth. Because the remote
   location is a pure function of the photo, sync state can always be rebuilt
   from scratch by listing the cloud folders.
3. **Content hash** — the tiebreaker when something already exists at the
   target path. Same size + same hash → already uploaded, mark synced, skip.

Rejected: local-state-only (a reinstall or a second device would re-upload
everything) and hash-only (needs a whole-corpus hash lookup, and `imoHash` is
sampled, so it is a strong duplicate *candidate* signal rather than proof).

**Hard safety rule:** never overwrite an existing remote file. If the target
path is occupied by different content, upload under a disambiguated name.

Consequences: `imoHash` must be reimplemented in Dart (16 KB samples,
murmur3-128, varint size prefix), and the index needs a bulk query returning
path + size + hash so that a cold start reconciles in a few paginated calls
instead of thousands of HEAD requests.

## D3 — Mirror layout, relative path preserved

**Decided.** A Sync Pair maps `local folder → cloud folder`, recursively, with
the relative path preserved. `DCIM/Camera/2026/IMG_0001.jpg` under
`DCIM/Camera → /Photos/Phone` lands at `/Photos/Phone/2026/IMG_0001.jpg`.

Rejected: date-derived layout (`/Photos/Phone/2026/07/…`). It violates D2's
pure-function requirement, because capture date is *not* a stable property of a
file: EXIF is absent for screenshots and received images, forcing a fallback to
mtime, which changes when a file is copied or restored — so the same photo
would map to different remote paths at different times and get uploaded twice.

Collisions resolve by suffix, never by overwrite. Missing intermediate
directories are created on demand — note `thumbnailer.Start()` already carries
a `TODO` about recursive mkdir being unsupported, so this is a real gap in the
file-provider layer.

**Decided.** A Sync Pair's cloud folder automatically becomes a Gallery Source
Folder, and Gallery Source Folders remain independently configurable so that
folders nothing uploads to can also appear in the gallery.

## D4 — Config split: pairs on the device, gallery folders on the server

**Decided.**

- **Sync Pairs** live in the app's local database. They reference paths that
  exist on exactly one phone. Losing them to a data wipe costs a
  reconfiguration, not data — D2 rebuilds sync state from the cloud folders.
- **Gallery Source Folders** live server-side, per user, owned by a **new
  `gallery` service**.

Reasoning: gallery folders are a user-level preference that a second device and
the web UI should both see — but the decisive argument is that the
**thumbnail pre-generator is a backend consumer of `FileChangedEvent` and
cannot read a setting stored on a phone.**

Rejected: folding gallery config and queries into `file-indexer` (puts
user-facing configuration behind the indexer's boundary), and a server
`config.yaml` listing folder prefixes (the app could then not offer folder
selection, contradicting the requirement).

The `files` collection stays private to `file-indexer`; the gallery service
reaches it through events and NATS request/reply, never directly.

## D5 — Capture Date as ordering key, via a gallery read model

**Decided.** Gallery Mode orders by **Capture Date**, extracted from EXIF
`DateTimeOriginal`, with the fallback chain `EXIF → file mtime → indexed-at`.
Extraction happens **server-side**, so photos that arrive by other routes (SMB
copy, web upload) sort correctly too.

The failure this avoids: mtime cannot survive upload today, so cloud-side
`modTime` is *upload* time. Restoring a phone and re-uploading 4,000 photos
from 2019 would pile all of them onto today's date — and the same photo would
show one date while on the device and jump to another once local space was
freed.

**Decided.** The `gallery` service maintains its **own read model** of gallery
items, built by consuming file-change events filtered to the configured Gallery
Source Folders, holding `(providerId, path, capturedAt, dimensions,
orientation, size, hash)` and indexed on `(capturedAt, _id)` for cursor paging.

Reasoning: the indexer's collection covers documents, music and backups too, so
a gallery page would be a filtered sort over the whole corpus; `capturedAt` does
not belong in the indexer; the same event subscription that builds the read
model is exactly where thumbnail pre-generation should fire; and EXIF gets
parsed only when a file actually appears or changes.

### Aside — `Chtimes` support (investigated, kept separate)

Setting mtime over WebDAV is **not** standards-supported: RFC 4918 §15.7 says
`DAV:getlastmodified` "SHOULD be protected", and `x/net/webdav` enforces this
by returning `403 cannot-modify-protected-property` for any PROPPATCH touching
a live property. The de-facto convention is the ownCloud/Nextcloud `X-OC-Mtime`
header on PUT, which rclone and all Nextcloud clients speak.

Implementing it in Seraph is roughly four touch points: a `Chtimes` message
pair in the file-provider protocol; an optional backend interface (the dir
provider wraps `os.Chtimes`, `go-smb2` already exposes `(*Share).Chtimes`); a
read-only guard in `limited_fs.go`; and an `X-OC-Mtime` hook wrapped *around*
the WebDAV handler, since `webdav.FileSystem` has no such method.

**Decided:** worth doing for file fidelity and rclone/Nextcloud-client
compatibility, but it is *not* a substitute for `capturedAt` and is **not on
the Gallery Mode critical path**. mtime approximates capture time only for
camera originals; for downloads and received images it is when the bytes
landed. Track it as a separate change.

## D6 — Local mirror on the device, fed by a delta API

**Decided.** The app keeps a local SQLite mirror of *all* gallery items — cloud
ones synced through a delta API, device ones imported from MediaStore — so the
merged view is a single indexed `ORDER BY capturedAt DESC` query and dedup
happens at write time.

Rejected: a lazy two-cursor merge over MediaStore and the server. Item counts
would be unknown (so no date scrubber, no honest scrollbar), dedup after paging
makes pages collapse and the layout shift mid-scroll, and every scroll would
need the network.

Consequences, both real:

- The gallery service must expose a **change feed**: a monotonic `seq` per
  item, bumped on change, with **tombstone rows for removals** — a mirror
  without tombstones silently keeps showing photos that no longer exist. The
  app polls `?since=<seq>`. This is needed regardless, or "my other phone
  uploaded 200 photos" is only discoverable by re-listing everything.
- The app gains its **first local database** (`sqflite`/`drift`) and its first
  schema-migration story. Sync state, the mirror and the UI list should be one
  table, not three.

## D7 — Android first, behind a platform-neutral local-source seam

**Decided.** The device half ships for **Android only** in this iteration. On
iOS, desktop and web the app shows a **cloud-only gallery** — same
chronological grid, every item `Cloud only`, no upload.

Reasoning: iOS has no user-visible photo folders. The library is a flat set of
`PHAsset`s in albums, with opaque on-disk names, so the *relative path* that
anchors D2/D3 does not exist there. Designing for iOS parity now would force
the date-derived layout rejected in D3.

**Design constraint that keeps iOS cheap later:** a Sync Pair's local side is
an opaque **local source** identifier, not a hardcoded directory path, and
"relative path within the source" is a value the platform-specific local-media
layer produces — from the real path on Android, later from album plus original
filename on iOS. The remote path stays a pure function of
`(sync pair, relative path)`; only the computation of the relative path is
platform-specific.

## D8 — Space-namespace config, physically-keyed read model

**Decided.** Gallery Mode straddles two coordinate systems and translates at
both ends:

- **Gallery Source Folders are configured in space terms** —
  `(spaceProviderId, path)`, exactly as the user picked them in a folder
  picker. Storing them physically would force the app to translate before
  saving and would make the config meaningless if an admin re-mounted the
  space.
- **The read model is keyed physically** — `(providerId, path)` — because that
  is what `FileChangedEvent` carries, and matching an event against the folder
  set must not require a resolve per event.
- **The API returns space paths**, resolved at query time, so the app can feed
  them straight into the existing `/preview?p=…` and `/download/p` endpoints
  with no new plumbing.

The payoff: **the read model is shared, the configuration is per user.** Two
users including `/Photos/Family` cost one EXIF extraction and one set of
thumbnails, while each still sees exactly the union of their own folders.

Access control falls out of this for free: a gallery query is scoped to the
requesting user's source folders, each resolved *for that user* at query time
via `SpaceResolveRequest`. Revoked access means resolution fails and the folder
yields nothing — no reverse physical→space mapping, no second permission check
to keep in sync.

**Decided.** Introduce a **`spaces.changed` event** as part of this work.
`spaces` currently publishes nothing — it only serves `seraph.spaces.resolve`
and `seraph.spaces.crud` request/reply — so the gallery service's physical
prefix set would otherwise be a resolution cache with no invalidation signal:
re-point a space at another provider and the gallery keeps consuming events for
the old physical path. A TTL was the cheap alternative; the event is the
correct one and is useful beyond Gallery Mode.

## D9 — Three-tier local change detection

**Decided.** The app notices local photos by three mechanisms with strict,
non-overlapping roles:

1. **Full MediaStore scan** — the *correctness anchor*. One projection-only
   cursor over `_ID`, `DATE_TAKEN`, `DATE_MODIFIED`, `SIZE`, `RELATIVE_PATH`,
   `DISPLAY_NAME`; sub-second for 10,000 images. Runs at app start and
   periodically.
2. **Generation-based incremental** — the *fast path*.
   `GENERATION_MODIFIED > watermark`, available unconditionally since the app's
   `minSdkVersion` is 34.
3. **ContentObserver** — a *trigger only*, so a new camera photo starts backing
   up within seconds.

**Rule:** no photo's backup status may ever depend on having received a
notification. A missed notification must degrade latency, never correctness —
which is what tier 1 guarantees.

**Decided.** Local identity is `(relative path, display name, size, date
taken)`, with MediaStore `_ID` as a hint only. `_ID` is not durable: a file
deleted and recreated, moved between folders, or restored by another app gets a
new row, and keying on it would re-upload the photo as if it were new. This is
the device-side mirror of D2.

**Decided.** Under Android 14's partial media grant
(`READ_MEDIA_VISUAL_USER_SELECTED` instead of `READ_MEDIA_IMAGES`), the app runs
in a **clearly-degraded mode with a visible warning** rather than blocking. It
must never report completeness it cannot verify — under partial access it can
only see hand-picked photos, so "everything is backed up" would be a lie.

Noted for later: deleting local photos requires `MediaStore.createDeleteRequest()`,
which shows a system confirmation dialog. This shapes the Erase and free-up-space
flows.

## D10 — Atomic publish, verification through the feed

**Decided.** An upload is never PUT to its final path. It goes to a temp name in
a staging folder and is `MOVE`d into place — the pattern `thumbnailer` already
uses (`_tmp` folder + `Rename`). Orphaned temp files are swept on a schedule.
The final path therefore either does not exist or holds a complete file, and the
"never overwrite" rule of D2 is checked immediately before the move.

**Decided.** The proof of a safe backup is not the client's HTTP response but
**Seraph independently reporting, through the delta feed, that it holds a file
of the expected name with matching size and hash.** Per-item device state:

`pending → uploading → uploaded (moved) → verified (seen in feed, size+hash match)`

Only `verified` may be shown to the user as backed up, and **only `verified`
items may be deleted locally to free space.** If verification never arrives the
item stays visibly un-backed-up — failing in the safe direction.

The failure this prevents: an interrupted PUT leaves a truncated file at the
final path; the next scan sees "something exists, wrong size", the D2 collision
rule fires, and you end up with a corrupt file *and* a duplicate — with EXIF
parsed from the truncated header.

Costs: a staging folder that needs sweeping; verification latency of seconds to
minutes, since indexing and EXIF extraction are asynchronous; and a state for
verification *contradicting* the upload (size mismatch), which means "delete the
remote file and retry" — the one case where the app deletes something remotely
on its own.

### Aside — this is not hypothetical (verified)

`x/net/webdav`'s `handlePut` opens the destination with
`os.O_RDWR|os.O_CREATE|os.O_TRUNC` and does `io.Copy(f, r.Body)` straight into
it; on copy error it returns 405 and performs **no rollback or cleanup**
(webdav.go:268-281). Seraph adds no buffering — `file.Write` forwards straight
through as ≤`maxPayload` NATS chunks (`client.go:526`).

RFC 4918 does not require PUT to be atomic (it mentions atomicity only for
PROPPATCH and collection-level MOVE/DELETE). Mature implementations chose
staging anyway: ownCloud/Nextcloud wrote to `.ocTransferId<id>.part` files and
later moved to a chunked `uploads/` staging area assembled by a final MOVE.
Apache `mod_dav_fs` streams into the destination and is known for leaving
partial files.

**Separate bug found while checking this:** `O_TRUNC` fires at open, *before*
any body bytes arrive, so a PUT over an existing file empties it first — a
failed overwrite destroys the old content unconditionally, for every client.
Gallery Mode dodges it by never overwriting; it needs its own fix and has been
filed separately.

## D11 — Headless sync engine, WorkManager plus foreground service

**Decided.** The sync engine runs in a **headless Dart isolate**, invoked two
ways:

- **WorkManager** — periodic work for unattended catch-up, expedited work when
  the ContentObserver fires. Constraints (unmetered network, charging,
  battery-not-low) are declared to the OS and enforced by it, not polled by us.
- **Foreground `dataSync` service** — for user-initiated batches, so a large
  backup survives the screen going off.

Rejected: a native Kotlin engine (duplicates the state machine, DB access and
auth handling outside Dart) and foreground-only execution (no unattended
catch-up).

Notes: the manifest currently declares only `FOREGROUND_SERVICE_MEDIA_PLAYBACK`
and needs `FOREGROUND_SERVICE_DATA_SYNC`. Android 15 caps cumulative `dataSync`
foreground runtime at ~6 hours/day, which is why WorkManager — not a long-lived
service — is the backbone.

**Decided.** The engine is **headless by construction**: no GetX controllers, no
`BuildContext`, no UI dependencies. **The local database is the interface
between the engine and the UI** — the engine writes state, the UI observes and
renders. This is a deliberate departure from the rest of the app, where
controllers hold `Rx` state.

**Decided.** Token refresh is guarded by a **DB-backed cross-isolate lock**.
With two isolates and rotating OIDC refresh tokens, concurrent refreshes mean
the second one presents an invalidated token and the user is silently logged
out — during an overnight backup, the worst possible moment. Only one refresh is
ever in flight; the loser re-reads the persisted token rather than refreshing
again.

## D12 — Queue policy

**Decided.**

- **Two priority classes.** Photos observed after setup (or after the last
  completed pass) preempt the historical backlog; newest-first within each
  class. Otherwise a photo taken right after configuring a 9,000-image backup
  lands at position 9,001.
- **3–4 parallel uploads**, tunable. Mobile radios have high latency and
  per-connection throughput limits, so parallelism hides latency more than it
  saturates bandwidth. Beyond ~4 you compete with yourself for the radio and
  the gateway's NATS request budget.
- **Three failure buckets**, handled differently:
  - *Transient* (network gone, 5xx, timeout) → per-item exponential backoff
    **plus a global backoff**, so a downed server does not produce thousands of
    independent retry storms.
  - *Permanent* (403 read-only space, 507 out of space, unreadable local file)
    → stop retrying, move to a **visible failure list** with a reason. Never
    silently dropped, never retried forever.
  - *Moved target* (local file changed or vanished mid-upload) → re-queue or
    discard; never mark synced.
- **The queue is derived state, not durable truth.** It is rebuildable at any
  time by diffing MediaStore against the verified set in the local mirror, so a
  lost or corrupted queue costs a scan, not a backup.

### Included in scope — buffer the WebDAV write path

**Decided.** Fix upload throughput as part of Gallery Mode (unlike the Chtimes
work, this is on the critical path, because upload speed is a stated
requirement).

Today `handlePut` does `io.Copy(f, r.Body)` where neither side implements the
fast-copy interfaces, so uploads move in **32 KB** chunks — and each chunk is
one NATS request/reply round trip (`client.go:543`), despite `maxPayload` being
**768 KB**. A 4 MB photo becomes ~128 sequential round trips instead of ~6;
across a 10,000-photo initial backup that is tens of minutes of pure latency,
worse with an SMB backend.

The download direction was already optimised — `fastResponseWriter.ReadFrom`
(512 KB) wraps the response at `webdav.go:124`, and `util.FastReader` (WriterTo,
512 KB) serves thumbnail bytes at `preview.go:222`. The request side was never
wrapped.

The remedy is to **buffer the writes, not enlarge the reads**: wrapping
`r.Body` in `FastReader` would not be enough, because `io.CopyBuffer` is a
read-then-write loop and an HTTP body `Read` returns as soon as *any* data
arrives — on a mobile connection, often far less than the buffer size. Instead
wrap the destination in `bufio.NewWriterSize(f, ~768KB)` so writes accumulate
close to `maxPayload` regardless of arrival pattern, flushing before close.
`thumbnailer` already writes this way.

## D13 — Index-backed backfill, idempotent read model

**Decided.** When a Gallery Source Folder is added, the read model is backfilled
by **querying `file-indexer` for everything under the `(providerId, path)`
prefix** via a new paged NATS request. The index already has the ideal access
path — a unique compound index on `(providerId, path)` — so this is a bounded
range scan, not a collection scan. Adding a folder stays instant and costs no
filesystem I/O.

An explicit **"Rescan folder"** action triggers a real file-provider re-scan for
the case where the index itself is behind. Index staleness is a pre-existing
property of Seraph; Gallery Mode neither fixes it nor pretends it away.

Rejected: making every folder-add trigger a full subtree re-scan (turns a
configuration change into a heavyweight server job), and walking the provider
directly from the gallery service (duplicates existing logic).

**Decided.** The read model is **idempotent on `(providerId, path)` — upsert,
never insert.** Backfill and live events race by construction: a folder being
backfilled while photos upload into it will see the same file arrive by both
paths.

## D14 — Thumbnail pre-generation via a JetStream work queue

**Decided.** Pre-generation is dispatched through a **new durable JetStream work
queue**, published fire-and-forget by the gallery service and consumed by the
thumbnailer with ack-on-completion. The existing interactive `/preview`
request/reply path is untouched.

The failure this avoids: the thumbnailer is a core-NATS request/reply service
(`ChanQueueSubscribe`, concurrency capped by `util.NewLimiter(NumCPU)`). Firing
8,000 backfill requests at it times out replies, breaches the pending-message
limit, and **core NATS silently drops the overflow** — with no record of which
thumbnails were never made.

**Decided.** The batch consumer gets its **own, smaller concurrency budget**, so
a backfill cannot monopolise every worker while a user waits on a `/preview` for
a photo they are looking at right now.

**Decided.** Warm exactly **one configurable grid size** (512 the realistic
default — a 3-column grid on a 1080p phone needs ~360 px per cell and sizes snap
upward). Larger viewer sizes stay on demand. ~320 MB for 8,000 photos rather
than over a gigabyte for all four sizes.

**Decided.** Thumbnail cleanup: the **thumbnailer subscribes to the durable
`SERAPH_FILE_CHANGED` JetStream stream** and removes thumbnails on deletion.
Confirmed the stream is durable (`CreateOrUpdateStream`, `consumer.go:87`), so a
durable consumer is straightforward.

Notes on the mechanics:

- There is no rename event — `Change` is only `created`/`changed`/`deleted`. A
  rename surfaces as delete-at-old + create-at-new, which is sufficient here.
- **`changed` events fix an existing staleness bug.** The thumbnail name is
  `hash(providerId + path)` plus size, with no mtime or size component, so
  editing a photo in place leaves the old thumbnail served forever. Invalidating
  on `changed` fixes that for the whole product, not just Gallery Mode.
- Thumbnail storage is a **flat folder** and names embed the dimensions, so
  "delete all thumbnails for this file" means attempting up to 16 W×H
  combinations, most returning `ErrNotExist`. Sharding storage by hash prefix
  would make this a cheap listing instead — and a flat folder holding 100k+
  files is its own scaling concern worth revisiting.

## D15 — Format scope: display and backup are different questions

**Decided.** Gallery Mode *displays* **JPEG and PNG** in this iteration. Video is
out of scope. HEIC is out of scope but designed for.

**The governing principle: backup coverage and gallery display are independent.**
A RAW file, a HEIC or a 200 MP JPEG must still be backed up safely even when we
cannot decode it for display. Conflating the two is how backup tools silently
skip files. The read model therefore records a per-item **`unsupported` reason**
rather than omitting the file, so unsupported items still appear in the gallery
with a placeholder and are still uploaded.

Findings that motivated this:

- The thumbnailer registers only `image/jpeg`, `image/png` and `image/gif`
  decoders (`thumbnailer.go:46-48`) — **no HEIC/HEIF, AVIF, WebP or RAW/DNG.**
  HEIC is the iPhone default and ships on recent Android flagships. Go has no
  standard HEIC decoder; supporting it means a cgo binding to libheif and a
  different build story for the thumbnailer container.
- Video would change three things at once: `capturedAt` from container metadata
  instead of EXIF, thumbnails via frame extraction (an ffmpeg dependency the
  thumbnailer does not have), and upload sizes jumping from ~4 MB to ~4 GB,
  which stresses atomic publish and retry in ways photos never will.

**Decided.** Raise the resolution cap **now**. `MaxImageWidth/Height = 8120`
(`thumbnailer.go:52`) rejects anything larger outright, so a 108 MP photo
(12000×9000) or Samsung's 200 MP mode (16320×12240) becomes a broken tile —
exactly the photos a user most wants visible. The cap legitimately bounds decode
memory, but its current value is already wrong for phones shipping today; raise
it and make it configurable.

**To investigate:** whether thumbnails can be produced faster than Go's `image`
package allows — e.g. libvips/`bimg`, `libjpeg-turbo` DCT-domain scaling, or
decoding embedded EXIF preview images (most camera JPEGs carry a full-size
preview that can be extracted without decoding the main image at all). Relevant
both to backfill throughput and to the resolution cap, since several of these
avoid full-resolution decode entirely.

## D16 — In-place edits produce a new Gallery Item

**Decided.** A photo edited in place after upload presents as a **new Gallery
Item** (local identity includes size, per D9), and publishes alongside the
original under a disambiguated name. **Seraph keeps both versions**, adjacent in
the gallery since they share a capture date.

Rejected: overwriting the cloud copy (violates never-overwrite, destroys the
original) and skipping the upload (the edit is never backed up while the app
reports `Synced` — silent data loss dressed as success).

In practice this fires rarely: most Android editors, including Google Photos by
default, write a new file rather than editing in place.

Possible later refinement: use MediaStore's `ORIGINAL_DOCUMENT_ID` to group a
derivative with its original in the UI as versions of one item. **Grouping
only — never fewer uploads.**

## D17 — Erase, free-up-space, and the erase tombstone

**Decided.** **Free up space** uses `MediaStore.createTrashRequest()`, not
`createDeleteRequest()`. Trashed photos stay recoverable for 30 days, turning a
mistake into an inconvenience; same single system dialog, accepts a batch of
URIs, costs nothing. Restricted to `verified` items only (D10). Afterwards the
mirror marks them `Cloud only` with no re-download.

**Decided.** **Erase** deletes the **remote copy first**, then **trashes** the
local copy. Rationale: for sensitive photos the urgent half is getting the file
off the server, and local trash still lets the user undo the local loss. Remote
deletion is unrecoverable — Seraph has no trash, `RemoveAll` goes straight to
the file provider — so the warning is the only safety net on that side.

**Decided.** This ordering requires an **erase tombstone** in the local DB, keyed
on local identity `(relative path, display name, size, date taken)`. Without it
the erase silently reverses itself in two cases:

1. Remote delete succeeds, user **cancels** the trash dialog → local copy still
   visible to MediaStore → re-uploaded on the next scan.
2. User **restores from trash** within 30 days → visible again → re-uploaded.

(While an item sits *in* the trash it is excluded from MediaStore queries, so
the scan will not see it.)

This is a much narrower thing than the tombstones postponed in D1: *we*
performed the erase and know exactly what we erased. Detecting deletions made
elsewhere (e.g. via the web UI) remains postponed.

**Semantics:** erase means erase. A locally restored photo lives on the device
only; the app offers an explicit "back this up again" rather than re-uploading
automatically, which would contradict an action confirmed through two dialogs.

**Accepted risk:** an item that is `Cloud only` after freeing space, then deleted
from Seraph by other means, is simply gone — the device has no local copy and
cannot notice. This is the tombstone gap of D1 seen from the other side.

## D18 — Sync Pair lifecycle

**Decided.** **Removing a Sync Pair stops future uploads and changes nothing
else.** Already-uploaded photos stay in Seraph and the cloud folder remains a
Gallery Source Folder. Only queued-but-not-yet-uploaded items are discarded. Any
behaviour where deleting a *setting* deletes *photos* is indefensible.

**Decided.** **Retargeting is delete-pair-plus-create-pair**, stated explicitly
in the UI: photos already backed up to the old target stay there; new photos go
to the new one. What must not happen is a silent re-upload of everything because
the remote path function started returning different answers.

**Decided.** **A local folder may appear in at most one Sync Pair.** Otherwise a
photo has two remote paths and two verification states, and D2's pure function
becomes a relation. Simple validation, real confusion avoided.

**Decided — correction to D2.** Two changes were needed to make "already
backed-up photos stay there" a claim that survives a config change:

- **The per-item record stores the remote path the photo actually went to**, not
  a recipe for deriving it. Recomputing from current config would produce wrong
  answers after a retarget.
- **A Sync Pair keeps its historical targets**, not just its current one. Writes
  go to the current target; existence checks consult all of them. The function
  stays deterministic: *current target for writes, all targets for lookups*.

Without these, a reinstall after a retarget would look only at the new target,
find nothing, and duplicate every photo. D2's original claim that local state is
"always rebuildable from the cloud folders" was wrong: it is rebuildable only
while the config that produced it is unchanged.

## D19 — No content hashing

**Decided.** No content hashes anywhere in Gallery Mode. Rationale: regular file
uploads in Seraph are not hash-verified either, and Gallery Mode should not
invent a stricter standard of its own.

This revises D2 and D10:

- **`verified` means** "Seraph reports a file at the expected path with the
  expected length". Atomic publish (D10) already prevents a truncated upload
  from masquerading as a complete file, which was the failure mode that
  motivated hashing in the first place. Undetected: in-transit corruption, which
  TCP and TLS make rare.
- **Reconcile is path+size** across current and historical targets (D18).
  Cross-device dedup and server-side folder reorganisation now produce duplicate
  uploads rather than being recognised. Duplicates waste space but lose nothing
   — the safe direction.
- **The collision rule becomes:** target path occupied and size differs →
  publish under a disambiguated name; size matches → assume it is ours and mark
  synced. The only case this gets wrong is an edit that leaves the file
  byte-identical in length; accepted.
- The read model and bulk lookup API need not carry a hash, and no `imoHash`
  reimplementation in Dart is required.

Alternatives considered and rejected: reusing `imoHash`
(`github.com/kalafut/imohash` — full-file below 128 KB, otherwise murmur3-128
over three 16 KB samples with a uvarint length prefix; a Dart reimplementation
that disagreed in any edge case would leave photos stuck in `uploaded` forever,
silently) and SHA-256 computed during upload streaming (unambiguous and free on
the device, but full-file reads server-side and inconsistent with how the rest
of Seraph treats uploads).

## D20 — Phasing

**Decided.** Build in this order. Whether to ship at the end of a phase is
decided when we get there, not now.

- **Phase 0 — server plumbing, invisible to users.** Write buffering on the PUT
  path (D12), raised resolution cap (D15), `spaces.changed` event (D8), paged
  prefix query on `file-indexer` for backfill (D13). None of it needs the app.
- **Phase 1 — cloud-only gallery, every platform.** The `gallery` service:
  source-folder config, read model, EXIF extraction, backfill, delta feed;
  gateway endpoints; app-side local DB, mirror and chronological grid.
  **Thumbnail warming belongs here**, not later — a cloud-only gallery is
  exactly where cold thumbnails hurt most.
- **Phase 2 — device side, Android.** MediaStore integration, local items in the
  mirror, the merged view, the three availability states. Useful on its own:
  browsing device and cloud photos as one stream with honest state labels.
- **Phase 3 — upload.** Sync pairs, the headless engine, WorkManager, atomic
  publish, verification, the failure list.
- **Phase 4 — space management.** Free-up-space via trash, erase with
  tombstones.

The ordering's payoff: the read model, delta feed and mirror — the three pieces
most likely to need revision — meet real data in Phase 1, before any upload
logic depends on them. Getting the delta feed wrong is far cheaper to discover
while nothing is uploading.

---

## Open questions

None of these are structural — the shape of the design does not depend on how
they land.

- **Delta feed mechanics.** Cursor semantics and page sizing.
- **Progress reporting.** `file-indexer` already publishes to `SERAPH_JOBS`, and
  backfill plus thumbnail warming are exactly the long-running operations a user
  would want to watch.
- **Viewing `Cloud only` photos at full resolution.** Download-on-demand and
  cache eviction policy on the device.
- **The same photo on two devices with different Sync Pairs** yields two cloud
  copies. Follows from D2/D19 and is harmless, but was never decided explicitly.
- **API surface for Erase**, and for the gallery queries generally.

## Deferred work identified along the way

Each of these is a real gap found while designing; none is required for Gallery
Mode.

- **Tombstones for remote deletions made elsewhere** (D1). A photo deleted from
  Seraph via the web UI, while the device still holds it, will be re-uploaded.
- **`Chtimes` support** (D5 aside). Preserving modification time through upload,
  via an `X-OC-Mtime` header on PUT and a `Chtimes` operation in the
  file-provider protocol. Improves file fidelity and rclone/Nextcloud-client
  compatibility.
- **Server-side atomic PUT** (D10 aside). `handlePut` truncates the destination
  before receiving data, so a failed overwrite destroys the old content — data
  loss for every WebDAV client, not just Gallery Mode. Filed separately.
- **Recursive mkdir in the file-provider layer** (D3). `thumbnailer.Start()`
  already carries a `TODO` about it.
- **Thumbnail storage sharding** (D14). A flat folder holding 100k+ files makes
  "delete all thumbnails for this file" a 16-attempt guess and readdir slow.
- **Faster thumbnail generation** (D15). libvips, `libjpeg-turbo` DCT-domain
  scaling, or extracting embedded EXIF previews — several of which avoid
  full-resolution decode entirely.
- **HEIC/HEIF support**, which needs a cgo binding to libheif and a different
  build story for the thumbnailer container.
- **Video in Gallery Mode**, which changes metadata extraction, thumbnailing and
  upload sizes all at once.
- **iOS device support**, kept cheap by the Local Source seam (D7).

---

## Postscript — 2026-08-01

The decisions above are left as they were written. This section records what
changed after the conversation closed, so that a reader can tell the record from
the current position without either being rewritten.

### D10 — client-side staging is dropped

D10 has the app upload to a temp name in a staging folder and `MOVE` it into
place, on the reasoning set out in its aside: `handlePut` streamed the request
body straight into the destination with no rollback, so an interrupted PUT left
a truncated file at the final path, the D2 collision rule would then mistake it
for real content, and the result was a corrupt file *and* a duplicate.

That failure has since been fixed at its source. The WebDAV layer now stages
**every** PUT itself and moves it into place on completion, so the final path is
either absent or complete for every client — rclone, Nextcloud clients, the web
UI and the app alike. Client-side staging would now be a second implementation
of a guarantee the server already makes, costing an extra round trip per photo
and a staging folder to sweep.

**The app therefore PUTs directly to the final path.** Everything else in D10
stands: never overwrite, disambiguate on collision, and treat a photo as backed
up only once the delta feed reports it back.

[ADR 0002](adr/0002-photo-upload-safety-model.md) has been amended to match.

### Deferred work — server-side atomic PUT is done

The "Server-side atomic PUT" entry in the deferred list above was closed on
2026-07-31, before Gallery Mode was specified. It is the change described
immediately above, and it is what made the D10 revision possible. The remaining
entries in that list are still open.

### Open questions

The open questions above were carried into the spec rather than resolved. The
`Chtimes` aside in D5 and the format, video, HEIC and iOS items remain out of
scope by the same reasoning recorded here.
