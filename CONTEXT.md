# Seraph

Seraph is a self-hosted WebDAV/CardDAV/CalDAV/Subsonic server for single-user,
family and home use. This file is the shared vocabulary — a glossary and
nothing else. Decisions live in [docs/adr/](docs/adr/).

## Language

### Storage and access

**File Provider**:
A service that exposes one filesystem — a local directory, an SMB share,
thumbnail storage — under a provider id. Files are addressed as a
`(providerId, path)` pair.
_Avoid_: backend, mount, storage adapter

**Space**:
A named grouping of file providers, mounted at chosen paths and assigned to
users. Spaces are the unit of access control; clients browse spaces, never raw
providers.
_Avoid_: share, volume, folder

**File Index**:
The searchable record of every known file, derived from file provider events.
_Avoid_: database, catalogue

**Thumbnail**:
A cached, downscaled rendering of a file at one of a fixed set of sizes.
_Avoid_: preview (that is the endpoint that serves them), miniature

### Gallery Mode

**Gallery Mode**:
The app experience that presents photos held on the device and photos held in
Seraph as one continuous, chronologically ordered collection, hiding where each
one physically lives.
_Avoid_: photos view, album view

**Gallery Item**:
A single photo as the user perceives it, independent of how many copies exist.
One item may be backed by a copy on the device, a copy in Seraph, or both.
_Avoid_: photo, asset, media item, file

**Availability**:
Where a Gallery Item's copies currently are — exactly one of *Device only*,
*Synced*, or *Cloud only*.
_Avoid_: sync status, state, location

**Capture Date**:
When a photo was taken, as opposed to when its file was written or uploaded.
The ordering key of Gallery Mode, read from the photo itself; where the photo
does not say, Seraph falls back to the file's modification time, and failing
that, to when Seraph first saw it.
_Avoid_: date taken, timestamp, modification time, upload date

**Sync Pair**:
A configured mapping from one Local Source on a device to one folder in Seraph.
Photos found in the source are uploaded to the matching location under the
Seraph folder, preserving their relative path. A Sync Pair belongs to the device
that holds its Local Source.
_Avoid_: backup rule, folder mapping, sync job

**Local Source**:
The device-side half of a Sync Pair: wherever photos come from on this device,
together with a relative path for each one. On Android that is a folder and the
paths beneath it; the term stays deliberately vague about *how* a device
organises photos, because not every platform has folders.
_Avoid_: camera folder, DCIM, local album

**Gallery Source Folder**:
A folder in Seraph whose photos appear in Gallery Mode. Every Sync Pair's Seraph
folder is one; further ones can be added on their own, for photos Seraph holds
but no device uploads. They belong to the user, not to a device.
_Avoid_: gallery folder, album, watched folder

**Upload**:
The one-way transfer of a Gallery Item from device to Seraph. Seraph never
pushes photos back to the device automatically, and neither side's deletions
propagate to the other.
_Avoid_: sync, backup, transfer

**Verified**:
Seraph has independently confirmed that it holds a Gallery Item's photo.
Distinct from having finished uploading it: a Verified photo is one Seraph
reports back as present, not one the device believes it sent. Only Verified
photos may have their device copy removed.
_Avoid_: uploaded, backed up, confirmed

**Erase**:
An explicit, user-initiated action that removes both the Seraph copy and the
device copy of a Gallery Item. Distinct from deleting on one side, which never
affects the other.
_Avoid_: delete, purge, remove everywhere
