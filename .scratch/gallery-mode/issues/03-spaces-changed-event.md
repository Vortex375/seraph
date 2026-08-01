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

**Status:** resolved

- [x] Creating, updating and deleting a Space each publish a `spaces.changed` event
- [x] The event identifies the affected Space and the kind of change, and carries enough that a consumer knows to re-resolve rather than having to guess
- [x] The event follows the existing Avro schema and topic conventions used elsewhere in the project, with generated sources regenerated from the schema rather than hand-edited
- [x] Publishing failures do not fail the originating CRUD operation
- [x] Covered by extending the existing `spaces` integration test: issue a CRUD request, assert the event is published with the expected payload

## Comments

### Implementer report — base `b524946`

**Schema and topics** (`events/schema.avsc`, `events/topics.go`,
`events/constants.go`, `events/events.go`) — added a `SpaceChangedEvent` Avro
record (`event`, `spaceId`, `change`) alongside the existing `FileChangedEvent`,
plus `SpaceChangedStream`, `SpaceChangedTopic` (`seraph.spaces.*.changed`) and
`SpaceChangedTopicPattern`, mirroring the `FileChangedEvent`/`FileChangedTopic`
convention. `events.go` regenerated via `make` (avrogen).

**Publishing** (`spaces/spaces/spaces.go`) — added `Js jetstream.JetStream` to
`Params` (already provided by `messaging.Module` via fx, so no `main.go` change),
create the `SERAPH_SPACES_CHANGED` stream in `New()`, and publish via plain
`nc.Publish` after CREATE/UPDATE/DELETE succeed in `handleCrud`, matching
`file-indexer`'s `publishChange` pattern. Publish and marshal errors are logged and
swallowed; the CRUD response is built from the DB result *before* publishing is
attempted, so a broker hiccup cannot fail the RPC.

**Tests** (`spaces/spaces/spaces_integration_test.go`) — enabled JetStream on the
embedded NATS server, wired a `jetstream.JetStream` client into the test's
`SpacesProvider` construction, and added `TestSpaceChangedEvent` asserting an event
with the right `spaceId`/`change` for each of create, update and delete.

**Decisions the ticket did not settle:** chose `created`/`updated`/`deleted` as the
`change` values (matching `FileChangedEvent`'s shape but using "updated", which fits
CRUD terminology); chose a per-space topic `seraph.spaces.<id>.changed` with a
stream-wide wildcard subject rather than one shared topic, following the existing
`FileChangedEvent` pattern and letting consumers subscribe narrowly.

### Verifier verdict — APPROVED

1. **Core publish into a JetStream stream is correct, not dead config.** A
   `nc.Publish` to a subject matching a stream is captured durably by the server
   regardless of which publish API produced it, so a consumer that was down still
   learns of the change on reconnect. It faithfully mirrors `file-indexer`'s
   existing `publishChange`/`SERAPH_FILE_CHANGED` pattern — same `nc.Publish`, same
   producer-side stream setup.
2. `publishSpaceChanged` returns nothing and only logs its errors; the CRUD
   response is built and returned independently — confirmed by reading `handleCrud`
   rather than trusting the claim.
3. `avrogen -pkg events -encoders -tags json:camel -o events.go schema.avsc`
   reproduces the committed `events/events.go` byte-for-byte — not hand-edited.
4. `TestSpaceChangedEvent` asserts actual payload contents for all three of create,
   update and delete — `SpaceID`, `Change`, and `Event.ID`/`Event.Version` for
   create — not merely that some message arrived.
5. Full `spaces` and `events` suites pass under `-race`.
