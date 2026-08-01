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

**Status:** resolved

- [x] A PUT of several megabytes reaches the file provider in a bounded number of write operations, on the order of size divided by maximum payload rather than size divided by 32 KB
- [x] The buffer is flushed before the destination is closed, so no bytes are lost on a successful upload
- [x] An aborted upload still discards cleanly and leaves no partial file at the final path — existing atomic-PUT behaviour is unchanged
- [x] Uploads whose length is unknown (chunked transfer encoding) work unchanged
- [x] The buffer size is derived from the file provider's maximum payload rather than hardcoded independently of it
- [x] Extends the existing atomic-PUT integration test, asserting the observable protocol consequence — the number of write operations reaching the provider for a given payload size

## Comments

### Implementer report — base `9f3b4fc`

**Files changed:**

- `api-gateway/webdav/atomic_put.go` — `atomicPutFs.OpenFile` wraps the staging
  file's writer in a `bufio.Writer` sized to `fileprovider.MaxPayload` (768 KB).
  `stagedFile.Write` goes through the buffer; `stagedFile.Close()` flushes before
  closing the underlying file, ahead of the existing abort/commit decision — so a
  dropped connection still discards the staging file whole, and a successful
  upload loses no bytes.
- `file-provider/fileprovider/client.go`, `server_file.go` — exported the
  previously-unexported `maxPayload` as `MaxPayload` so the webdav module derives
  its buffer size from it rather than hardcoding a second number.
- `api-gateway/webdav/atomic_put_integration_test.go` — extended the existing
  multi-chunk-upload test with a NATS-level write counter (a second subscriber on
  the file's request subject, since request/reply is plain pub/sub underneath) and
  asserts a 3 MiB upload reaches the provider in at most `ceil(size/MaxPayload)`
  `FileWriteRequest` messages. Observed 2–4 writes, versus ~96 before the fix.

**Decision the ticket did not settle:** how to make the buffer size "derived from
the file provider's maximum payload". Exported `fileprovider.MaxPayload` (a rename
of the existing unexported constant) rather than introducing a new shared constant,
since `api-gateway` already depends on `fileprovider` via `go.work`.

**Noticed, out of scope:** the thumbnailer's `bufferSize` (512 KB) is hardcoded
independently of `fileprovider.MaxPayload` — the same pattern this ticket forbade
for webdav. Left untouched; this ticket scoped only the WebDAV write path.

### Verifier verdict — APPROVED

All acceptance criteria satisfied:

1. Bounded write count verified by the new `wantMaxWrites` assertion, passing.
2. Buffer flushed before close — `f.buf.Flush()` precedes `f.File.Close()`.
3. Abort/atomicity unchanged — `aborted()`/`discard()` untouched, tests pass.
4. Chunked/unknown-length uploads unaffected — `bufio.Writer` is length-agnostic
   and the flush in `Close()` is unconditional; existing test still passes.
5. Buffer size derived from `fileprovider.MaxPayload`, now a single source of
   truth shared with the client chunking logic — not hardcoded.
6. The destination (`f.File`, the staging file) is wrapped, not the request body —
   the `trackingBody` wrapping is pre-existing and unrelated to buffering.
7. Integration test extended to assert the observable write count.

Full `webdav` and `file-provider` suites pass, including under `-race`.
