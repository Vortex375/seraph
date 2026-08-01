# 03 — Publish a `spaces.changed` event

**What to build:** Any service that caches the resolution of a Space to a File
Provider needs to know when that resolution stops being true. `spaces` currently
publishes nothing at all — it only serves resolve and CRUD request/reply — so a
consumer holding resolved physical locations has no invalidation signal, and
re-pointing a Space at a different File Provider leaves that consumer working
against the old physical path indefinitely.

Publish a `spaces.changed` event on create, update and delete, carrying enough
for a consumer to tell which Space changed and re-resolve it. A TTL was the
cheap alternative; the event is the correct one and is useful well beyond
Gallery Mode.

**Blocked by:** None — can start immediately.

**Status:** claimed

- [ ] Creating, updating and deleting a Space each publish a `spaces.changed` event
- [ ] The event identifies the affected Space and the kind of change, and carries enough that a consumer knows to re-resolve rather than having to guess
- [ ] The event follows the existing Avro schema and topic conventions used elsewhere in the project, with generated sources regenerated from the schema rather than hand-edited
- [ ] Publishing failures do not fail the originating CRUD operation
- [ ] Covered by extending the existing `spaces` integration test: issue a CRUD request, assert the event is published with the expected payload
