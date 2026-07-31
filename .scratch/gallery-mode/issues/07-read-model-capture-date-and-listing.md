# 07 — Read model, Capture Date and the paged listing

**What to build:** A photo copied into a Gallery Source Folder — over WebDAV,
over SMB, through the web UI, by any route at all — appears in a
capture-date-ordered listing of that user's gallery, newest first, paged.

This is the tracer bullet through the gallery service's core. The service
consumes the durable file-change stream, filters events to the resolved physical
prefixes of the configured Gallery Source Folders, extracts photo metadata, and
maintains its own read model. A paged query returns that user's photos in
Capture Date order.

**Capture Date is derived server-side** with the fallback chain `EXIF
DateTimeOriginal → file modification time → time first indexed`. Server-side so
that photos arriving by other routes sort correctly too. Record which rung of
the chain produced the value, so the UI can present a fallback date differently
from a real capture date.

**Modification time is not an acceptable ordering key and must not be used as
one.** It cannot survive Seraph's upload path today, so cloud-side modification
time is *upload* time — re-uploading years of photos after a phone restore would
pile all of them onto today.

**Two coordinate systems, translated at both ends.** Configuration is in Space
terms; **the read model is keyed physically on `(providerId, path)`** because
that is what the file-change event carries and matching an event against the
folder set must not cost a resolve per event; **the API returns Space paths**,
resolved at query time, so the app can feed them straight into the existing
preview and download endpoints with no new plumbing.

**Access control falls out of this.** A query is scoped to the requesting user's
Gallery Source Folders, each resolved *for that user* at query time. Revoked
access means resolution fails and that folder contributes nothing. There is no
reverse physical-to-space mapping and no second permission check to keep in
sync.

**The read model is shared while configuration is per user** — two users
including the same family folder cost one metadata extraction, not two.

**Backup coverage and display are independent questions.** A file the service
cannot decode is recorded with an `unsupported` reason rather than omitted, so
it still appears in the gallery. Omitting it is how backup tools silently skip
files.

**Blocked by:** 06

**Status:** ready-for-agent

- [ ] A photo appearing in a configured folder shows up in that user's listing, at the position its Capture Date implies
- [ ] Capture Date comes from the photo's own metadata where present, falling back to modification time and then to when it was first seen, with the source of the value recorded
- [ ] Pixel dimensions and orientation are recorded, so portrait photos can be displayed the right way up
- [ ] A file the service cannot decode is recorded with an `unsupported` reason and still appears in the listing
- [ ] A photo with a nonsensical embedded date still appears rather than being rejected
- [ ] A corrupt or truncated file fails for that item alone and does not stop the folder from loading
- [ ] The listing is paged with a stable cursor; paging through thousands of photos yields each exactly once
- [ ] The listing returns Space paths that work directly against the existing preview and download endpoints
- [ ] A user sees exactly the union of their own Gallery Source Folders and nothing else
- [ ] A user whose access to a Space has been revoked sees no photos from it
- [ ] The read model is upserted on `(providerId, path)`, never inserted, so the same file arriving twice produces one item
- [ ] A `deleted` event removes the photo from the listing
- [ ] Events for files outside every configured folder are ignored cheaply, without a resolve per event
- [ ] Covered at the gallery service's NATS boundary: publish file-change events, assert on listing responses. Photo fixtures are served through a stubbed File Provider responder and Space resolution through a stubbed resolve responder, both on the same bus
