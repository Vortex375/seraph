# 10 — Delta feed with tombstones

**What to build:** A client that has seen every gallery change up to a point can
ask for everything after it and miss nothing — including removals. This is what
lets the app hold a local mirror instead of re-listing the whole gallery, and it
is how "my other phone uploaded 200 photos" becomes discoverable at all.

Every read-model document carries a **monotonic sequence** bumped on every
change. **Removals produce tombstone rows, not deletions** — a mirror without
tombstones silently keeps showing photos that no longer exist. The client polls
with the last sequence it saw and receives a page of changed items plus a cursor
to continue from.

The feed is scoped to the requesting user's Gallery Source Folders, resolved at
request time, so it inherits exactly the same access control as the listing.

Cursor semantics and page sizing are open; the requirement is that a client
which has seen everything up to a sequence and asks for everything after it
misses nothing, and that the feed is resumable across app restarts.

**Blocked by:** 07

**Status:** claimed

- [ ] A client polling from a given sequence receives every item changed since, and nothing it has already seen
- [ ] A deleted photo arrives as a tombstone, so a mirror can remove it
- [ ] A photo that changes twice between two polls is delivered once, in its current state
- [ ] The feed is paged, with a cursor that survives an app restart
- [ ] Polling from sequence zero yields the user's entire gallery, so a mirror can cold-start from the feed alone
- [ ] A folder added or removed between polls is reflected without the client needing to know it happened
- [ ] The feed returns Space paths, consistent with the listing
- [ ] A user never receives items from another user's folders, and revoked access stops delivery
- [ ] Sequence values are monotonic and never reused, including across service restarts
- [ ] Covered at the gallery service's NATS boundary, including a test that publishes changes between two polls and asserts nothing is missed and nothing is duplicated
