# 12 — App local database and mirror from the delta feed

**What to build:** The app keeps a local mirror of the user's gallery, synced
through the delta feed, so browsing is a local indexed query rather than a
network round trip per screen. This is the app's **first local database** and
its first schema-migration story, and both need to be set up properly here
because everything after this ticket depends on them.

**Sync state, the mirror and the UI list are one table, not three.** Cloud items
arrive through the delta feed; device items will later be imported from the
media store into the same table; dedup happens at write time. That is what makes
the merged view a single indexed query ordered by Capture Date.

The alternative — a lazy two-cursor merge over the device and the server — was
rejected and must not be reintroduced: item counts would be unknown, so no date
scrubber and no honest scrollbar; dedup after paging makes pages collapse and
the layout shift mid-scroll; and every scroll would need the network.

No UI in this ticket. It is verifiable by driving the mirror and inspecting what
it returns.

**Blocked by:** 10

**Status:** ready-for-agent

- [ ] The app has a local database with a migration mechanism that survives an app upgrade adding a column
- [ ] A cold start with no local data populates the mirror from the delta feed
- [ ] A subsequent sync applies only changes since the last seen sequence
- [ ] A tombstone removes the item from the mirror
- [ ] The sync cursor survives an app restart, so a restart does not re-fetch the whole gallery
- [ ] A sync interrupted mid-page resumes without losing or duplicating items
- [ ] The mirror can be queried in Capture Date order, paged, and reports a total count
- [ ] Querying the mirror works with no network available
- [ ] Covered at the app's mirror seam: a stubbed HTTP backend feeds the delta feed, assertions read the mirror's query results — following the existing chat service tests' approach to stubbing HTTP
