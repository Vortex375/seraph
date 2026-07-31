# Gallery Mode

Status: ready-for-agent

Design record: [docs/gallery-mode-design-notes.md](../../docs/gallery-mode-design-notes.md)
Vocabulary: [CONTEXT.md](../../CONTEXT.md)
Architecture decisions: [ADR 0001](../../docs/adr/0001-gallery-read-model-and-device-mirror.md),
[ADR 0002](../../docs/adr/0002-photo-upload-safety-model.md)

## Problem Statement

A person running Seraph at home has photos in two places that have nothing to do
with each other. Some are on the phone, in the camera roll, where the phone's
own gallery app shows them in the order they were taken. Others are in Seraph —
copied off an old laptop, dropped in over SMB, uploaded through the web UI — and
the only way to see those is to browse folders one directory at a time, in
alphabetical order, with no thumbnails until each one is opened. There is no
view anywhere that answers "show me my photos, newest first", because no such
view can exist: Seraph has no API that lists images across folders in date
order, and the app has no way to merge two sources into one list.

The gap costs the user in three separate ways.

Photos on the phone are not backed up. The only routes into Seraph today are
manual — pick files, upload them, remember which ones you already did. Nobody
does this reliably for four thousand photos, so the phone remains a single point
of failure for the one category of file people most regret losing.

The phone fills up and there is nothing safe to do about it. Deleting photos to
reclaim space means deciding, photo by photo, whether a copy exists somewhere
else, with no reliable way to check. So people either delete photos they had no
second copy of, or they never free anything and buy a bigger phone.

And the photos already in Seraph are effectively invisible. They are the ones
from the old laptop, the scanned negatives, the shared family folder — often the
most valuable ones — and they sit behind a folder tree that nobody browses for
pleasure.

The user does not think of these as three problems. They think: *my photos
should be in one place, in order, and I should not have to worry about losing
them.*

## Solution

Gallery Mode presents photos held on the device and photos held in Seraph as one
continuous, chronologically ordered collection, and hides which is which unless
the user asks.

Opening Gallery Mode shows a grid of thumbnails ordered by **Capture Date** —
when the photo was taken, not when its file was written or uploaded — newest
first, scrolling back through the entire collection. A photo on the phone and
the same photo in Seraph appear as one **Gallery Item**, once. Each item carries
an **Availability**: *Device only*, *Synced*, or *Cloud only*. The distinction is
available on demand and filterable, but it never fragments the ordering.

The user chooses which folders in Seraph feed the gallery — its **Gallery Source
Folders** — and these belong to the user, not to a device, so a second phone and
the web UI see the same set. Because Seraph reads Capture Date from the photo
itself, photos that arrive by any route at all — SMB copy, web upload, another
phone — sort into their correct place in history.

On Android, the user additionally configures **Sync Pairs**: a folder on the
phone maps to a folder in Seraph, and everything under it is uploaded, relative
path preserved, in the background, on the constraints the user picks (unmetered,
charging, and so on). Upload is strictly one way. Seraph never pushes photos
back and deletions never propagate — the cloud copy is a backup, and a backup
that can be destroyed by the thing it backs up is not one.

A photo counts as backed up only once Seraph independently reports it back —
**Verified** — not when the upload's HTTP response said 201. Only Verified
photos may have their device copy removed, and freeing space uses the Android
trash, so a mistake is recoverable for thirty days. For the case where the user
genuinely wants a photo gone, an explicit **Erase** removes both copies at once,
behind a clear warning.

On iOS, desktop and web, Gallery Mode shows the same chronological grid of
Seraph's photos, every item *Cloud only*, with no upload. The device half is
Android-only in this iteration.

## User Stories

### Browsing the gallery

1. As a photo owner, I want to open Gallery Mode and see my photos as a grid of thumbnails, so that I can recognise photos at a glance instead of reading filenames.
2. As a photo owner, I want the grid ordered by Capture Date with the newest first, so that the collection reads as a timeline of my life rather than an alphabetical file listing.
3. As a photo owner, I want photos on my phone and photos in Seraph interleaved in one list, so that I do not have to remember where a photo lives in order to find it.
4. As a photo owner, I want a photo that exists both on my phone and in Seraph to appear exactly once, so that my gallery is not half duplicates.
5. As a photo owner, I want to scroll back through thousands of photos without the list stalling on the network, so that browsing feels like a local app.
6. As a photo owner, I want scroll position and item count to stay stable as I scroll, so that the grid does not shift under my thumb as more items load.
7. As a photo owner, I want date headings as I scroll, so that I can tell roughly when I am in my history.
8. As a photo owner, I want a scrubber that lets me jump to a point in time, so that reaching photos from three years ago does not take three minutes of flicking.
9. As a photo owner, I want to tap a photo and see it full screen, so that I can actually look at it.
10. As a photo owner, I want to swipe between photos in the full-screen viewer in the same order as the grid, so that the two views agree.
11. As a photo owner, I want the gallery to work when I am offline, showing what is on the device and the thumbnails already cached, so that a train journey does not empty my gallery.
12. As a photo owner, I want the gallery to open quickly even the first time after an update, so that it does not feel like it rebuilds itself.

### Knowing where a photo lives

13. As a photo owner, I want each Gallery Item to have exactly one Availability — Device only, Synced, or Cloud only — so that "where is this photo" has a single unambiguous answer.
14. As a photo owner, I want Availability shown discreetly on the tile rather than shouting from every thumbnail, so that the gallery still looks like a gallery.
15. As a photo owner, I want to filter the gallery to photos that are not yet backed up, so that I can see at a glance what I would lose if I dropped my phone.
16. As a photo owner, I want to filter to Cloud only photos, so that I can see what is in Seraph but no longer on this device.
17. As a photo owner, I want to see a summary of how many photos are backed up and how many are not, so that I have one number to trust rather than a feeling.
18. As a photo owner, I want a photo that has been uploaded but not yet confirmed by Seraph to be shown as still in progress rather than as backed up, so that the app never claims safety it cannot demonstrate.
19. As a photo owner, I want to open a Cloud only photo at full resolution, so that freeing space on my phone does not make those photos unviewable.
20. As a photo owner, I want to see which Seraph folder a photo lives in when I ask for its details, so that I can find it again through the file browser or over WebDAV.

### Gallery Source Folders

21. As a photo owner, I want to choose which folders in Seraph appear in Gallery Mode, so that a folder of scanned documents does not pollute my photo timeline.
22. As a photo owner, I want to pick those folders with the same folder picker I already use elsewhere in the app, so that I do not have to type paths.
23. As a photo owner, I want my choice of Gallery Source Folders to be stored on the server against my account, so that a second device and the web UI show the same gallery.
24. As a photo owner, I want a folder I add to fill the gallery with the photos already in it, not just photos added from now on, so that adding a folder is not a promise about the future only.
25. As a photo owner, I want adding a folder to be instant, so that configuring the gallery does not block on a scan of ten thousand files.
26. As a photo owner, I want to remove a Gallery Source Folder and have its photos leave the gallery, without any file being deleted, so that curating my gallery is never dangerous.
27. As a photo owner, I want a "Rescan folder" action for when I know Seraph's index is behind reality, so that I have a way to force the issue without an administrator.
28. As a photo owner, I want nested Gallery Source Folders to not produce duplicate items, so that adding a parent folder after a child folder does not double my gallery.
29. As a photo owner sharing a folder with another user, I want each of us to see that folder's photos in our own gallery without the other's folders leaking in, so that a shared family folder works and nothing else is shared.
30. As a photo owner whose access to a space is revoked, I want the photos from that space to stop appearing in my gallery, so that access control is not bypassed by the gallery.
31. As a Seraph administrator, I want re-pointing a space at a different file provider to be picked up by the gallery, so that reorganising storage does not leave the gallery serving stale locations.

### Capture Date

32. As a photo owner, I want the ordering date read from the photo itself, so that a photo taken in 2019 sits in 2019 even if it was uploaded today.
33. As a photo owner restoring a phone and re-uploading years of photos, I want them to land in their correct places in the timeline, so that a restore does not flatten my history onto one day.
34. As a photo owner, I want a photo with no capture date in it to fall back to the file's modification time, and failing that to when Seraph first saw it, so that undated photos still appear somewhere sensible rather than disappearing.
35. As a photo owner, I want a photo to keep the same position in the timeline whether it is on the device, in Seraph, or both, so that the item does not jump when I free up space.
36. As a photo owner, I want photos to display in their correct rotation, so that portrait shots are not shown on their side.
37. As a photo owner whose photo has a nonsensical capture date embedded in it, I want the gallery to still show it rather than reject it, so that one bad file does not vanish silently.

### Thumbnails

38. As a photo owner, I want thumbnails for photos in Seraph to be ready before I scroll to them, so that the gallery is not a grid of grey placeholders.
39. As a photo owner, I want thumbnail warming to happen in the background without making the rest of Seraph unresponsive, so that generating eight thousand thumbnails does not take the server down.
40. As a photo owner looking at a photo right now, I want its thumbnail request to be served ahead of a bulk warming batch, so that background work never makes the foreground slower.
41. As a photo owner, I want a photo I edited in place to show its new appearance rather than its old thumbnail, so that the gallery does not lie about what a file contains.
42. As a Seraph administrator, I want thumbnails removed when their file is deleted, so that thumbnail storage does not grow without bound.
43. As a photo owner with a 108-megapixel phone, I want my highest-resolution photos to have thumbnails like every other photo, so that the pictures I care most about are not the broken tiles.
44. As a Seraph administrator, I want the resolution limit for thumbnailing to be configurable, so that I can trade memory against coverage on my own hardware.
45. As a Seraph administrator, I want to configure which single thumbnail size is warmed ahead of time, so that I can match it to the devices I actually use without paying for all four sizes.

### Sync Pairs and upload (Android)

46. As an Android photo owner, I want to map a folder on my phone to a folder in Seraph, so that everything I photograph is backed up without me doing anything further.
47. As an Android photo owner, I want the folder structure under my phone folder preserved in Seraph, so that the backup is browsable and restorable as files rather than as an opaque blob.
48. As an Android photo owner, I want a Sync Pair's Seraph folder to become a Gallery Source Folder automatically, so that I do not have to configure the same folder twice.
49. As an Android photo owner, I want to set up more than one Sync Pair, so that my camera folder and my screenshots folder can go to different places in Seraph.
50. As an Android photo owner, I want to be told when I try to add a phone folder that is already in another Sync Pair, so that a photo never has two backup destinations.
51. As an Android photo owner, I want a new photo to start backing up within seconds of taking it, so that the photos most at risk are protected soonest.
52. As an Android photo owner, I want photos taken after setup to be uploaded before the historical backlog, so that a photo taken today is not queued behind nine thousand old ones.
53. As an Android photo owner, I want the historical backlog uploaded newest first, so that the photos I am most likely to want are protected first.
54. As an Android photo owner, I want to choose whether uploads run only on unmetered networks, only while charging, and only above a battery threshold, so that backup never costs me data or a dead battery.
55. As an Android photo owner, I want uploads to continue when the app is closed and the screen is off, so that a large backup completes overnight rather than requiring me to hold the phone.
56. As an Android photo owner, I want to start a backup run immediately and watch its progress, so that I can push a batch through before leaving the house.
57. As an Android photo owner, I want to pause and resume backup, so that I can stop it competing for bandwidth when I need the network.
58. As an Android photo owner, I want to see how many photos remain and roughly how much data, so that I know whether this is a two-minute job or an overnight one.
59. As an Android photo owner, I want an upload interrupted by a lost connection to resume or restart cleanly, so that a flaky connection costs time and not correctness.
60. As an Android photo owner, I want an upload never to overwrite a file already in Seraph, so that backing up can never destroy something already backed up.
61. As an Android photo owner, I want a photo whose target name is already taken by different content to be uploaded under a disambiguated name, so that nothing is silently skipped and nothing is silently replaced.
62. As an Android photo owner, I want a photo counted as backed up only once Seraph reports holding it at the expected path and length, so that "backed up" is Seraph's claim and not my phone's.
63. As an Android photo owner, I want a photo whose verification never arrives to keep showing as not backed up, so that the failure mode is a false alarm rather than false confidence.
64. As an Android photo owner, I want photos that failed permanently — read-only space, server full, unreadable file — collected in a visible list with the reason, so that failures are something I can act on rather than something I never learn about.
65. As an Android photo owner, I want to retry the failure list, so that fixing the underlying cause does not require reconfiguring anything.
66. As an Android photo owner, I want transient failures retried automatically with increasing delays, and the whole queue to back off when Seraph is down, so that an outage does not drain my battery with a retry storm.
67. As an Android photo owner, I want a photo I deleted or moved while it was uploading to be dropped or re-queued rather than marked backed up, so that the record never claims something that did not happen.
68. As an Android photo owner, I want the backup queue rebuilt automatically if it is ever lost, so that a crash costs a scan and not a backup.
69. As an Android photo owner, I want a photo edited in place after upload to be backed up as a new item alongside the original, so that the edit is protected and the original is not destroyed.
70. As an Android photo owner, I want reinstalling the app not to re-upload everything, so that a reinstall is not a data-transfer event.
71. As an Android photo owner, I want to remove a Sync Pair without anything already uploaded being deleted, so that removing a setting never removes photos.
72. As an Android photo owner, I want retargeting a Sync Pair to leave already-backed-up photos where they are and send only new ones to the new folder, so that changing my mind does not duplicate my whole library.
73. As an Android photo owner, I want to be told plainly what retargeting will and will not do before I confirm it, so that the outcome is not a surprise.
74. As an Android photo owner, I want my session to survive a long overnight backup, so that I do not wake up logged out with nothing uploaded.
75. As an Android photo owner, I want to see when the last successful backup pass completed, so that silence is distinguishable from success.

### Permissions and platform reality

76. As an Android photo owner, I want to be asked for photo access with an explanation of what it is for, so that the request does not look like an overreach.
77. As an Android photo owner who granted access to only selected photos, I want the app to keep working on those photos while clearly warning that it cannot see the rest, so that I am never told everything is backed up when the app cannot know that.
78. As an Android photo owner who denied photo access, I want the cloud-only gallery to still work, so that refusing one permission does not disable the feature entirely.
79. As an iOS, desktop or web user, I want Gallery Mode to show Seraph's photos in the same chronological grid, so that the feature is not Android-exclusive even though upload is.
80. As an iOS, desktop or web user, I want upload and device-related controls hidden rather than shown broken, so that the app does not advertise something it cannot do here.

### Freeing space and erasing

81. As an Android photo owner, I want to free up space by removing device copies of photos Seraph already holds, so that I can keep using my phone without buying a new one.
82. As an Android photo owner, I want only Verified photos offered for freeing, so that this action can never delete a photo's only copy.
83. As an Android photo owner, I want freed photos moved to the Android trash rather than deleted outright, so that a mistake is recoverable for thirty days.
84. As an Android photo owner, I want to see how much space a free-up run will reclaim before confirming it, so that the decision is informed.
85. As an Android photo owner, I want freed photos to stay in the gallery as Cloud only, so that freeing space shrinks my storage and not my gallery.
86. As a photo owner, I want an explicit Erase that removes a photo from both Seraph and the device, so that a photo I genuinely want gone can be made gone.
87. As a photo owner, I want Erase to warn me clearly that the Seraph copy is not recoverable, so that I understand this is different from every other delete in the app.
88. As a photo owner, I want Erase to remove the Seraph copy first, so that the urgent half of the action — getting the file off the server — happens even if I then cancel the local step.
89. As a photo owner who cancels the device-deletion dialog during an Erase, I want the photo not to be re-uploaded on the next scan, so that the erase is not silently undone.
90. As a photo owner who restores an erased photo from the Android trash, I want it to stay on the device only and not re-upload itself, so that a two-dialog confirmation is respected.
91. As a photo owner, I want an explicit way to back up a photo again after erasing it, so that changing my mind is possible but never accidental.
92. As a photo owner, I want to erase a batch of photos in one action, so that clearing out a set does not mean confirming ninety dialogs.

### Formats and edge cases

93. As a photo owner, I want photos Seraph cannot render a thumbnail for to still appear in the gallery with a placeholder, so that the gallery is an honest inventory rather than a filtered one.
94. As an Android photo owner, I want files Seraph cannot display — RAW, HEIC, anything unusual — still uploaded and backed up, so that backup coverage is never limited by display support.
95. As a photo owner, I want to be told why an item cannot be displayed, so that a placeholder is informative rather than a bug report.
96. As a photo owner, I want a truncated or corrupt file in a Gallery Source Folder to fail visibly for that one item, so that one bad file does not stop the folder from loading.

### Server-side and operations

97. As a Seraph administrator, I want the gallery service to be a service like the others — same configuration, logging, tracing and deployment shape — so that operating it requires nothing new to learn.
98. As a Seraph administrator, I want the gallery read model shared across users, so that two users watching the same family folder cost one metadata extraction and one set of thumbnails.
99. As a Seraph administrator, I want uploads over WebDAV to use the available message size rather than 32 KB chunks, so that a large initial backup is not dominated by round-trip latency.
100. As a WebDAV user of any client, I want the faster upload path to apply to all uploads and not just the app's, so that the improvement benefits rclone, Nextcloud clients and the web UI too.
101. As a Seraph administrator, I want long-running backfill and thumbnail warming to report progress the way other long operations do, so that I can tell a slow job from a stuck one.
102. As a Seraph administrator, I want the gallery's read model to survive being fed the same file twice, so that a backfill running while photos upload does not produce duplicates.
103. As a Seraph administrator, I want the gallery service to reach the File Index through its published interface rather than its database, so that the indexer's storage stays private to it.

## Implementation Decisions

### Phasing

Build in the order below. Whether to ship at the end of a phase is decided when
we get there. The ordering exists so that the read model, the delta feed and the
device mirror — the three pieces most likely to need revision — meet real data
before any upload logic depends on them.

- **Phase 0 — server plumbing, invisible to users.** Write buffering on the PUT
  path, raised and configurable thumbnailer resolution cap, the `spaces.changed`
  event, and the paged prefix query on `file-indexer`. None of it needs the app.
- **Phase 1 — cloud-only gallery, every platform.** The `gallery` service:
  Gallery Source Folder configuration, read model, Capture Date extraction,
  backfill, delta feed. Gateway endpoints. App-side local database, mirror and
  chronological grid. **Thumbnail warming belongs in this phase** — a cloud-only
  gallery is exactly where cold thumbnails hurt most.
- **Phase 2 — device side, Android.** Local media integration, device items in
  the mirror, the merged view, the three Availability states.
- **Phase 3 — upload.** Sync Pairs, the headless engine, background scheduling,
  verification, the failure list.
- **Phase 4 — space management.** Free-up-space via the Android trash, Erase
  with tombstones.

### New service: `gallery`

A new Go microservice module alongside `spaces` and `shares`, following the
established shape: its own `go.mod`, `fx` modules, `Params`/`Result` structs,
MongoDB collections with the existing migrations mechanism, `logging.Logger` and
`tracing` wired the same way, NATS request/reply for its API.

It owns two collections:

- **Gallery Source Folder configuration**, per user, keyed by
  `(userId, spaceProviderId, path)`.
- **The gallery read model**, one document per photo, keyed physically on
  `(providerId, path)`.

It never reads another service's collections. The File Index is reached over
NATS request/reply; space resolution goes through `SpaceResolveRequest`.

### Two coordinate systems, translated at both ends

Gallery Mode straddles space coordinates and physical coordinates, and this is
deliberate rather than incidental.

- **Configuration is stored in space terms** — `(spaceProviderId, path)`,
  exactly as the user picked it in a folder picker. Storing it physically would
  force the app to translate before saving and would silently invalidate the
  configuration whenever an administrator re-mounted a space.
- **The read model is keyed physically** — `(providerId, path)` — because that
  is what `FileChangedEvent` carries. Matching an incoming event against the
  configured folder set must not cost a resolve per event.
- **The API returns space paths**, resolved at query time, so the app can feed
  them straight into the existing preview and download endpoints with no new
  plumbing.

The payoff is that **the read model is shared while configuration is per user**.
Two users including the same family folder cost one metadata extraction and one
set of thumbnails, and each still sees exactly the union of their own folders.

**Access control falls out of this.** A gallery query is scoped to the
requesting user's Gallery Source Folders, each resolved *for that user* at query
time. Revoked access means resolution fails and that folder contributes nothing.
There is no reverse physical→space mapping and no second permission check to
keep in sync.

### Read model contents and ordering

Each read-model document holds at least: physical key `(providerId, path)`,
`capturedAt`, pixel dimensions, orientation, size, mime type, a monotonic `seq`,
a deleted flag, and — where the item cannot be displayed — an `unsupported`
reason. It is indexed on `(capturedAt, _id)` for cursor paging and on `seq` for
the delta feed.

**`capturedAt` is derived server-side** with the fallback chain `EXIF
DateTimeOriginal → file modification time → time first indexed`. Server-side so
that photos arriving over SMB or the web UI sort correctly too. The value is
recorded together with which rung of the chain produced it, so the UI can
present a fallback date differently from a real capture date.

**Modification time is not an acceptable ordering key** and this is not
negotiable: it cannot survive Seraph's upload path today, so cloud-side
modification time is *upload* time.

**The read model is idempotent on `(providerId, path)` — upsert, never insert.**
Backfill and live events race by construction.

**Rejected:** querying `file-indexer` directly (the index covers documents,
music and backups, so every gallery page becomes a filtered sort over the whole
corpus; and `capturedAt` does not belong behind the indexer's boundary).

### How the read model is fed

- **Live**: the gallery service consumes the durable `SERAPH_FILE_CHANGED`
  JetStream stream, filtering events to the resolved physical prefixes of the
  configured Gallery Source Folders. `created` and `changed` upsert, `deleted`
  writes a tombstone.
- **Backfill**: adding a Gallery Source Folder issues a **new paged prefix query
  to `file-indexer`** over NATS — everything under a `(providerId, path)`
  prefix, paged. The index already carries a unique compound index on
  `(providerId, path)`, so this is a bounded range scan rather than a collection
  scan. Adding a folder stays instant and costs no filesystem I/O.
- **Rescan**: an explicit user action triggers a real file-provider re-scan, for
  the case where the index itself is behind. Index staleness is a pre-existing
  property of Seraph; Gallery Mode neither fixes it nor pretends it away.

**Rejected:** making every folder-add trigger a full subtree re-scan (turns a
configuration change into a heavyweight server job), and walking the file
provider directly from the gallery service (duplicates logic that already
exists).

### `spaces.changed`

`spaces` currently publishes nothing — it only serves resolve and CRUD
request/reply. The gallery service's set of physical prefixes is a cache of
space resolutions, and without an invalidation signal, re-pointing a space at
another provider leaves the gallery consuming events for the old physical path
indefinitely.

Add a `spaces.changed` event, published on space create, update and delete. The
gallery service subscribes and re-resolves affected folders. A TTL was the cheap
alternative; the event is the correct one and is useful beyond Gallery Mode.

### The delta feed

The app mirrors the read model locally, so the gallery service exposes a change
feed rather than only a paged listing:

- Every read-model document carries a **monotonic `seq`**, bumped on every
  change.
- **Removals produce tombstone rows**, not deletions. A mirror without
  tombstones silently keeps showing photos that no longer exist.
- The app polls `since=<seq>` and receives a page of changed items plus the
  cursor to continue from.
- The feed is scoped to the requesting user's folders, resolved at request time,
  so it inherits the same access control as the query path.

Cursor semantics and page sizing are left to implementation; the requirement is
that a client which has seen every row up to `seq` and asks for everything after
it misses nothing, and that the feed is resumable across app restarts.

### Thumbnail warming

Dispatch pre-generation through a **new durable JetStream work queue**, published
fire-and-forget by the gallery service and consumed by the thumbnailer with
ack-on-completion. The existing interactive request/reply preview path is
untouched.

The failure this avoids is specific: the thumbnailer is a core-NATS
request/reply service with concurrency capped at `NumCPU`. Firing eight thousand
backfill requests at it times out replies, breaches the pending-message limit,
and **core NATS silently drops the overflow** — with no record of which
thumbnails were never made.

- The batch consumer gets its **own, smaller concurrency budget**, so a backfill
  cannot monopolise every worker while a user waits on a preview for a photo
  they are looking at right now.
- Warm exactly **one configurable size**, 512 the realistic default: a
  three-column grid on a 1080p phone needs roughly 360 px per cell and sizes snap
  upward. Larger viewer sizes stay on demand. Roughly 320 MB for 8,000 photos
  rather than over a gigabyte for all four sizes.
- The thumbnailer additionally subscribes to `SERAPH_FILE_CHANGED` with a
  durable consumer and **removes thumbnails on `deleted`, invalidates on
  `changed`**. Invalidation on `changed` fixes an existing product-wide
  staleness bug: the thumbnail name is derived from `(providerId, path)` and
  size with no modification-time or size component, so editing a photo in place
  currently leaves the old thumbnail served forever.

There is no rename event — `Change` is only `created`/`changed`/`deleted`, and a
rename surfaces as delete-at-old plus create-at-new, which is sufficient here.

### Thumbnailer resolution cap

Raise the maximum thumbnailable image dimensions and make the limit
configurable. The current 8120-pixel cap rejects a 108 MP photo (12000×9000) or
Samsung's 200 MP mode (16320×12240) outright, turning exactly the photos a user
most wants visible into broken tiles. The cap legitimately bounds decode memory;
its current value is simply wrong for phones shipping today.

### WebDAV upload throughput

**Buffer the writes; do not enlarge the reads.** Today the WebDAV PUT path
copies the request body into the destination in 32 KB chunks, and each chunk is
one NATS request/reply round trip against the file provider — despite the
maximum payload being 768 KB. A 4 MB photo becomes roughly 128 sequential round
trips instead of about 6; across a 10,000-photo initial backup that is tens of
minutes of pure latency, worse with an SMB backend.

Wrapping the request body in a larger reader is **not** sufficient: the copy is a
read-then-write loop, and an HTTP body read returns as soon as *any* data
arrives — on a mobile connection, often far less than the buffer size. Wrap the
**destination** in a buffered writer sized close to the maximum payload so that
writes accumulate regardless of arrival pattern, flushing before close. The
thumbnailer already writes this way; the download direction was already
optimised and only the request side was ever left unwrapped.

This benefits every WebDAV client, not just the app.

### Upload safety model

**Upload is one way.** Device → Seraph, always. Deleting on either side never
affects the other. The cloud copy is a backup, and propagating cloud-side
deletions to the device means a server bug or a mis-resolved space path can
destroy the user's only copy.

**Never overwrite an existing remote file.** If the target path is occupied by
content of a different size, publish under a disambiguated name. If the size
matches, assume it is ours and mark it synced. The only case this gets wrong is
an edit that leaves the file byte-identical in length; accepted.

**No content hashing anywhere.** Regular file uploads in Seraph are not
hash-verified either, and Gallery Mode should not invent a stricter standard of
its own. Reconcile is path-plus-size. The consequence is that cross-device
duplicates and server-side folder reorganisation produce duplicate uploads rather
than being recognised — duplicates waste space but lose nothing, which is the
safe direction. No Dart reimplementation of `imoHash` is required, and neither
the read model nor the bulk lookup API needs to carry a hash.

**Client-side staging is not required.** ADR 0002 called for the app to PUT to a
staging name and MOVE it into place. Server-side atomic PUT has since landed:
the WebDAV layer stages every PUT itself and moves it into place on completion,
so the final path is already either absent or complete for every client. The app
therefore **PUTs directly to the final path**. The never-overwrite rule and
feed-based verification are unchanged; only the app-side staging folder and its
sweeper are dropped from scope.

**Verification is the delta feed, not the HTTP response.** Per-item device state:

```
pending → uploading → uploaded → verified
```

`verified` means Seraph reported, through the delta feed, a file at the expected
path with the expected length. Only `verified` may be shown to the user as
backed up, and **only `verified` items may have their device copy removed.** If
verification never arrives the item stays visibly un-backed-up — failing in the
safe direction. Verification *contradicting* the upload (a length mismatch)
means delete the remote file and retry; this is the one case where the app
deletes something remotely on its own.

### Remote path is a pure function

A Sync Pair maps one Local Source to one folder in Seraph, recursively, with the
relative path preserved: `DCIM/Camera/2026/IMG_0001.jpg` under
`DCIM/Camera → /Photos/Phone` lands at `/Photos/Phone/2026/IMG_0001.jpg`.

**Rejected: a date-derived layout** (`/Photos/Phone/2026/07/…`). Capture date is
not a stable property of a file — EXIF is absent for screenshots and received
images, forcing a fallback to modification time, which changes when a file is
copied or restored. The same photo would therefore map to different remote paths
at different times and be uploaded twice.

Missing intermediate directories are created on demand. Note that recursive
mkdir is not currently supported in the file-provider layer and this is a real
gap that Gallery Mode will hit.

Two corrections that make "already backed-up photos stay put" survive a
configuration change:

- **The per-item record stores the remote path the photo actually went to**, not
  a recipe for deriving it. Recomputing from current configuration produces
  wrong answers after a retarget.
- **A Sync Pair keeps its historical targets**, not just its current one. Writes
  go to the current target; existence checks consult all of them. The rule is
  *current target for writes, all targets for lookups*.

Without these, a reinstall after a retarget would look only at the new target,
find nothing, and duplicate every photo.

### Sync Pair lifecycle

- **Removing a Sync Pair stops future uploads and changes nothing else.**
  Already-uploaded photos stay in Seraph; the cloud folder remains a Gallery
  Source Folder; only queued-but-not-yet-uploaded items are discarded. Any
  behaviour where deleting a *setting* deletes *photos* is indefensible.
- **Retargeting is delete-pair-plus-create-pair**, stated explicitly in the UI.
- **A Local Source may appear in at most one Sync Pair.** Otherwise a photo has
  two remote paths and two verification states, and the pure function becomes a
  relation.

### Configuration split

- **Sync Pairs live in the app's local database.** They reference a Local Source
  that exists on exactly one device. Losing them to a data wipe costs a
  reconfiguration, not data.
- **Gallery Source Folders live server-side, per user**, owned by the `gallery`
  service.

The decisive argument for the split is not preference sharing but that the
**thumbnail pre-generator is a backend consumer of file-change events and cannot
read a setting stored on a phone.**

**Rejected:** folding gallery configuration and queries into `file-indexer`
(puts user-facing configuration behind the indexer's boundary), and a
server-side config file listing folder prefixes (the app could then not offer
folder selection).

### Android first, behind a platform-neutral Local Source seam

The device half ships for **Android only** in this iteration. On iOS, desktop and
web the app shows a cloud-only gallery — same chronological grid, every item
*Cloud only*, no upload.

iOS has no user-visible photo folders; its library is a flat set of assets in
albums with opaque on-disk names, so the *relative path* that anchors the remote
path function does not exist there. Designing for iOS parity now would force the
date-derived layout that was rejected above.

**The constraint that keeps iOS cheap later:** a Sync Pair's local side is an
opaque **Local Source** identifier, not a hardcoded directory path, and
"relative path within the source" is a value the platform-specific local-media
layer produces — from the real path on Android, later from album plus original
filename on iOS. The remote path stays a pure function of
`(Sync Pair, relative path)`; only the computation of the relative path is
platform-specific.

### Device-side change detection

Three mechanisms with strict, non-overlapping roles:

1. **Full media-store scan** — the *correctness anchor*. One projection-only
   cursor over id, date taken, date modified, size, relative path and display
   name; sub-second for 10,000 images. Runs at app start and periodically.
2. **Generation-based incremental scan** — the *fast path*, available
   unconditionally at the app's minimum SDK level.
3. **Content observer** — a *trigger only*, so a new camera photo starts backing
   up within seconds.

**Rule: no photo's backup status may ever depend on having received a
notification.** A missed notification must degrade latency, never correctness —
which is what the full scan guarantees.

**Local identity is `(relative path, display name, size, date taken)`**, with the
media-store row id as a hint only. The id is not durable: a file deleted and
recreated, moved between folders, or restored by another app gets a new row, and
keying on it would re-upload the photo as if it were new.

Under Android 14's partial media grant, the app runs in a **clearly-degraded mode
with a visible warning** rather than blocking. It must never report completeness
it cannot verify.

### Device-side architecture

The app gains its **first local database** and its first schema-migration story.
**Sync state, the mirror and the UI list are one table, not three.** Cloud items
arrive through the delta feed; device items are imported from the media store;
dedup happens at write time, so the merged view is a single indexed
`ORDER BY capturedAt DESC` query.

**Rejected: a lazy two-cursor merge** over the media store and the server. Item
counts would be unknown (so no date scrubber and no honest scrollbar), dedup
after paging makes pages collapse and the layout shift mid-scroll, and every
scroll would need the network.

The sync engine runs in a **headless Dart isolate**, invoked two ways: periodic
and expedited background work for unattended catch-up, and a foreground data-sync
service for user-initiated batches so a large backup survives the screen going
off. The manifest currently declares only media-playback foreground service type
and needs the data-sync type added. Android 15 caps cumulative data-sync
foreground runtime at roughly six hours per day, which is why scheduled
background work — not a long-lived service — is the backbone.

**The engine is headless by construction**: no GetX controllers, no
`BuildContext`, no UI dependencies. **The local database is the interface between
the engine and the UI** — the engine writes state, the UI observes and renders.
This is a deliberate departure from the rest of the app, where controllers hold
`Rx` state.

**Token refresh is guarded by a database-backed cross-isolate lock.** With two
isolates and rotating OIDC refresh tokens, concurrent refreshes mean the second
presents an invalidated token and the user is silently logged out — during an
overnight backup, the worst possible moment. Only one refresh is ever in flight;
the loser re-reads the persisted token rather than refreshing again.

### Queue policy

- **Two priority classes.** Photos observed after setup, or after the last
  completed pass, preempt the historical backlog; newest-first within each class.
  Otherwise a photo taken right after configuring a 9,000-image backup lands at
  position 9,001.
- **Three to four parallel uploads**, tunable. Mobile radios have high latency
  and per-connection throughput limits, so parallelism hides latency more than it
  saturates bandwidth. Beyond about four you compete with yourself for the radio
  and for the gateway's NATS request budget.
- **Three failure buckets, handled differently.** *Transient* (network gone, 5xx,
  timeout) → per-item exponential backoff **plus a global backoff**, so a downed
  server does not produce thousands of independent retry storms. *Permanent* (403
  read-only space, 507 out of space, unreadable local file) → stop retrying, move
  to a **visible failure list** with a reason; never silently dropped, never
  retried forever. *Moved target* (local file changed or vanished mid-upload) →
  re-queue or discard, never mark synced.
- **The queue is derived state, not durable truth.** It is rebuildable at any
  time by diffing the media store against the verified set in the local mirror,
  so a lost or corrupted queue costs a scan, not a backup.

### Space management

- **Free up space** uses the Android trash request, not the delete request.
  Trashed photos stay recoverable for thirty days, turning a mistake into an
  inconvenience; same single system dialog, accepts a batch. Restricted to
  `verified` items only. Afterwards the mirror marks them *Cloud only* with no
  re-download.
- **Erase deletes the remote copy first, then trashes the local copy.** For
  sensitive photos the urgent half is getting the file off the server, and local
  trash still lets the user undo the local loss. Remote deletion is
  unrecoverable — Seraph has no trash — so the warning is the only safety net on
  that side.
- **This ordering requires an erase tombstone** in the local database, keyed on
  local identity. Without it the erase silently reverses itself in two cases: the
  user cancels the trash dialog, so the local copy is still visible and gets
  re-uploaded; or the user restores from trash within thirty days, same result.
  (While an item sits *in* the trash it is excluded from media-store queries, so
  the scan will not see it.) This is much narrower than general remote-deletion
  tombstones: *we* performed the erase and know exactly what we erased.
- **Erase means erase.** A locally restored photo lives on the device only; the
  app offers an explicit "back this up again" rather than re-uploading
  automatically, which would contradict an action confirmed through two dialogs.

### Format scope

**Gallery Mode displays JPEG and PNG in this iteration**, and the governing
principle is that **backup coverage and gallery display are independent
questions**. A RAW file, a HEIC or a 200 MP JPEG must still be backed up safely
even when we cannot decode it for display — conflating the two is how backup
tools silently skip files.

The read model therefore records a per-item **`unsupported` reason** rather than
omitting the file. Unsupported items still appear in the gallery with a
placeholder and are still uploaded.

### In-place edits

A photo edited in place after upload presents as a **new Gallery Item** — local
identity includes size — and publishes alongside the original under a
disambiguated name. **Seraph keeps both versions**, adjacent in the gallery since
they share a capture date.

**Rejected:** overwriting the cloud copy (violates never-overwrite, destroys the
original) and skipping the upload (the edit is never backed up while the app
reports it synced — silent data loss dressed as success).

In practice this fires rarely: most Android editors, including Google Photos by
default, write a new file rather than editing in place.

### Gateway API surface

The api-gateway gains gallery endpoints behind the existing authenticated API
group, following the shape of the existing search and spaces endpoints: fan out
to the gallery service over NATS request/reply, translate the response, return
JSON. The endpoints cover Gallery Source Folder CRUD, the paged
capture-date-ordered listing, and the delta feed.

**Returned paths are space paths**, so the app feeds them directly into the
existing preview and download endpoints. No new media-serving endpoint is
introduced.

## Testing Decisions

### What makes a good test here

A good test drives a module through the interface its real callers use and
asserts on what those callers observe. For this feature that means: publish
events and issue requests over NATS, then assert on responses and on subsequent
requests — never on collection contents, internal struct fields or the number of
times a helper was called. A test that breaks when the read model is
re-normalised, but the API still returns the same photos in the same order, is a
test that was written at the wrong level.

Concretely: assert that a photo appears in the gallery listing at the right
position, not that a document was upserted. Assert that a delta request after
`seq` returns a tombstone, not that a `deleted` flag was set. Assert that
freeing space is refused for a non-verified item, not that a state field held a
particular value.

### Seams

The aim is one seam per subsystem, reusing the seams that already exist.

**1. The `gallery` service, at its NATS boundary — the primary seam.** Embedded
NATS server plus a MongoDB testcontainer plus `fxtest` lifecycle, exactly the
pattern of the existing `spaces` and `shares` integration tests. Everything the
gallery service does is tested here: read model construction from published
`FileChangedEvent`s, capture-date extraction and its fallback chain, folder
configuration CRUD, backfill against a stubbed indexer responder, the delta feed
and its tombstones, per-user access scoping through a stubbed
`SpaceResolveRequest` responder, `spaces.changed` invalidation, idempotency under
backfill/live races, and thumbnail-warm dispatch asserted as a publish onto the
work queue. EXIF fixtures are served through a stubbed file-provider responder on
the same bus, so no new seam is needed to test metadata extraction.

**2. The gateway HTTP boundary — existing seam.** `httptest` server plus embedded
NATS with a stubbed gallery responder, exactly the pattern of the existing search
integration test. Scope is deliberately narrow: authentication, request
validation, and space-path translation. Gallery *behaviour* is not re-tested
here; a test that would pass identically at seam 1 belongs at seam 1.

**3. `file-indexer`'s paged prefix query — new test file, existing kind of
seam.** Embedded NATS plus Mongo testcontainer, driving the new request over
NATS. `file-indexer` has no integration test today; this one follows the `spaces`
pattern. Covers paging, prefix boundaries (a folder named `/Photos2` must not
match the `/Photos` prefix), empty results, and stable ordering across pages.

**4. `spaces.changed` — existing seam.** Extend the existing `spaces` integration
test: issue a CRUD request, assert the event is published with the expected
payload. No new seam.

**5. Thumbnailer warm queue and invalidation — existing seam.** Extend the
existing thumbnailer tests: work-queue messages are consumed and acked,
`deleted` removes thumbnails, `changed` invalidates them, the batch consumer's
concurrency budget is separate from the interactive path, and the raised
resolution cap admits images the old cap rejected.

**6. WebDAV write buffering — existing seam.** The atomic-PUT integration test
already drives a real PUT over real NATS against a file provider. Extend it to
assert the observable protocol consequence: a PUT of a given size results in a
bounded number of write operations reaching the file provider, rather than one
per 32 KB. This is protocol behaviour, not an implementation detail — the number
of round trips *is* the requirement.

**7. The app's local mirror — the primary device-side seam.** Fake HTTP backend
(a stubbed Dio adapter, as the existing chat service tests do) and a fake Local
Source implementation feed the sync engine; assertions read the mirror's query
results. Because the local database is by design the interface between the
engine and the UI, this one seam covers delta-feed application, tombstone
handling, device/cloud dedup, Availability computation, ordering and paging, the
upload state machine including `verified`, the failure buckets, historical-target
lookup after a retarget, erase tombstones, and the refusal to free space for
non-verified items. Platform media-store and permission behaviour sit behind the
Local Source interface and are faked, not mocked out at a lower level.

Widget tests for the grid are worthwhile but secondary; they assert rendering
against a pre-populated mirror and must not be where gallery logic is verified.

### Prior art

- `spaces/spaces/spaces_integration_test.go` and `shares/shares/shares_integration_test.go`
  for the service-at-the-NATS-boundary pattern, including embedded NATS,
  testcontainer Mongo and per-run resource isolation.
- `api-gateway/search/search_integration_test.go` for the gateway HTTP pattern
  with a stubbed NATS responder.
- `api-gateway/webdav/atomic_put_integration_test.go` for driving a real PUT over
  real NATS against a file provider.
- `thumbnailer/thumbnailer/thumbnailer_test.go` for thumbnail generation with
  image fixtures.
- `app/seraph_app/test/chat/` for the Dart service/controller/widget split and
  for stubbing HTTP at the Dio adapter.

Integration tests requiring Docker follow the existing convention: they are part
of `go test ./...` for their module and assume Docker is available, as the
`spaces` tests already do.

## Out of Scope

- **Video.** Changes capture-date extraction (container metadata rather than
  EXIF), thumbnailing (frame extraction, an ffmpeg dependency the thumbnailer
  does not have) and upload sizes (about 4 MB to about 4 GB) all at once.
- **HEIC/HEIF display.** Needs a cgo binding to libheif and a different build
  story for the thumbnailer container. HEIC files are still backed up; they show
  a placeholder.
- **iOS device support.** Cloud-only gallery on iOS in this iteration. The Local
  Source seam exists to keep the later work cheap.
- **Tombstones for remote deletions made elsewhere.** A photo deleted from Seraph
  through the web UI while the device still holds it will be re-uploaded. The
  narrow erase tombstone is in scope; general remote-deletion detection is not.
- **`Chtimes` support** — preserving modification time through upload via an
  `X-OC-Mtime` header and a `Chtimes` operation in the file-provider protocol.
  Worth doing for file fidelity and rclone/Nextcloud-client compatibility, but it
  is not a substitute for capture date and is not on the critical path.
- **Recursive mkdir in the file-provider layer** as a general capability. Gallery
  Mode needs directory creation on demand and must handle it; hardening the
  file-provider abstraction generally is separate.
- **Thumbnail storage sharding.** A flat folder holding 100k+ files makes
  "delete every thumbnail for this file" a sixteen-attempt guess and makes
  directory listing slow. Real, but not required here.
- **Faster thumbnail generation** — libvips, DCT-domain scaling, or extracting
  embedded EXIF previews. Worth investigating for backfill throughput; not a
  prerequisite.
- **Downloading Cloud only photos back to the device in bulk.** Viewing them at
  full resolution on demand is in scope; a general restore-to-device flow is not.
- **Albums, tagging, faces, search within the gallery, editing, and sharing.**
  Gallery Mode is a chronological view plus backup.
- **Two-way sync of any kind.** Out of scope permanently, not merely deferred.
- **Web UI gallery.** The gallery service and gateway endpoints are built so the
  web app can consume them, but no web UI is built in this iteration.

## Further Notes

**Read the design record.** `docs/gallery-mode-design-notes.md` carries twenty
decisions with the reasoning and the rejected alternatives behind each. Where
this spec states a decision flatly, the notes explain what it is protecting
against. Anyone tempted to change one of these decisions should read the
corresponding entry first — several of them look arbitrary and are not.

**Two decisions are hard to reverse** and are recorded as ADRs: projecting
gallery data into its own service with a device-side mirror (ADR 0001), and the
upload safety model (ADR 0002).

**ADR 0002 has been amended** (2026-08-01) to drop client-side staging, since
server-side atomic PUT landed after it was accepted. Everything else in it —
one-way upload, never-overwrite, feed-based verification, no hashing — stands
unchanged.

**Gaps this feature will hit that were found while designing:** recursive mkdir
in the file-provider layer is unsupported (the thumbnailer already carries a TODO
about it); thumbnail names embed no size or modification time, so in-place edits
serve stale thumbnails until the invalidation work here lands; and the thumbnail
folder is flat, which makes bulk deletion a guessing game.

**Open questions that do not affect the shape of the design:** delta feed cursor
semantics and page sizing; whether backfill and thumbnail warming should report
progress through the existing jobs stream (`file-indexer` already publishes
there, and these are exactly the long-running operations a user would want to
watch); the cache-eviction policy for full-resolution Cloud only photos on the
device; and the API surface for Erase.

**One consequence worth stating explicitly** because it was never decided
head-on: the same photo on two devices with different Sync Pairs yields two cloud
copies. It follows from the no-hashing decision and is harmless — duplicates
waste space but lose nothing.

**Terminology is not decorative.** The glossary in `CONTEXT.md` names the terms
this feature is built out of — Gallery Item, Availability, Capture Date, Sync
Pair, Local Source, Gallery Source Folder, Upload, Verified, Erase — and lists
the words to avoid for each. Use them in code, in the API and in the UI. Several
of the near-synonyms marked *avoid* are exactly the confusions the design spent
effort escaping: "backed up" versus **Verified**, "sync" versus **Upload**, and
"date taken" versus **Capture Date**.
