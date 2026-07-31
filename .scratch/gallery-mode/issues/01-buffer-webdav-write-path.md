# 01 — Buffer the WebDAV write path

**What to build:** Uploading a file over WebDAV should move at the speed of the
connection rather than the speed of round trips. Today the PUT path copies the
request body into the destination in 32 KB chunks, and each chunk is one NATS
request/reply against the file provider, despite the maximum payload being
768 KB. A 4 MB photo becomes roughly 128 sequential round trips instead of about
six; across a large initial backup that is tens of minutes of pure latency,
worse against an SMB backend.

Wrap the **destination** in a buffered writer sized close to the maximum
payload, flushing before close. Wrapping the request body instead is not
sufficient and must not be the implementation: the copy is a read-then-write
loop and an HTTP body read returns as soon as *any* data arrives, which on a
mobile connection is routinely far less than the buffer size. The thumbnailer
already writes this way, and the download direction was already optimised — only
the request side was ever left unwrapped.

This benefits every WebDAV client, not just the app.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] A PUT of several megabytes reaches the file provider in a bounded number of write operations, on the order of size divided by maximum payload rather than size divided by 32 KB
- [ ] The buffer is flushed before the destination is closed, so no bytes are lost on a successful upload
- [ ] An aborted upload still discards cleanly and leaves no partial file at the final path — existing atomic-PUT behaviour is unchanged
- [ ] Uploads whose length is unknown (chunked transfer encoding) work unchanged
- [ ] The buffer size is derived from the file provider's maximum payload rather than hardcoded independently of it
- [ ] Extends the existing atomic-PUT integration test, asserting the observable protocol consequence — the number of write operations reaching the provider for a given payload size
