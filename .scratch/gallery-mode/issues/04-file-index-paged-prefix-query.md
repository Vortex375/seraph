# 04 — Paged prefix query on the File Index

**What to build:** A service should be able to ask the File Index for everything
it knows under a given `(providerId, path)` prefix, a page at a time, without
that service reaching into the indexer's storage. There is no such query today —
the only listing available anywhere is per-directory, one directory at a time.

The index already carries a unique compound index on `(providerId, path)`, so
this is a bounded range scan rather than a collection scan, and it must be
implemented as one. Expose it over NATS request/reply following the conventions
the indexer's existing search request already uses.

**Blocked by:** None — can start immediately.

**Status:** claimed

- [ ] A request for a `(providerId, path)` prefix returns the indexed files beneath it, paged, with a cursor to continue from
- [ ] Ordering is stable across pages, so a client paging through a large folder sees every entry exactly once
- [ ] Prefix matching respects directory boundaries — a folder named `/Photos2` must not match the `/Photos` prefix
- [ ] Each entry carries at least path, size, modification time, mime type and whether it is a directory
- [ ] An empty or unknown prefix returns an empty page rather than an error
- [ ] The query plan is a range scan over the existing compound index, verified rather than assumed
- [ ] Covered by a new `file-indexer` integration test following the `spaces` pattern — embedded NATS plus a MongoDB testcontainer — exercising paging, prefix boundaries, empty results and ordering stability
