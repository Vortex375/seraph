# 06 — Gallery service and Gallery Source Folder configuration

**What to build:** A user can choose which folders in Seraph feed Gallery Mode,
using the folder picker they already know from the file browser. The choice is
stored against their account on the server, so a second device and the web UI
see the same set. Removing a folder from the set never deletes a file.

This ticket stands up the new `gallery` service and takes one narrow path all
the way through it — configuration only, no photos yet. The service follows the
shape already established by `spaces` and `shares`: its own Go module, `fx`
wiring, MongoDB with the existing migrations mechanism, logging and tracing
wired the same way, NATS request/reply for its API. The api-gateway gains
authenticated endpoints that fan out to it, following the existing spaces and
search endpoints.

**Gallery Source Folders are stored in Space terms** — `(spaceProviderId, path)`
— exactly as the user picked them. Storing them physically would force the app
to translate before saving and would silently invalidate the configuration
whenever an administrator re-mounted a Space.

**Blocked by:** None — can start immediately.

**Status:** resolved

- [x] A user can list, add and remove their Gallery Source Folders through the gateway
- [x] Folders are stored per user in Space terms, and one user's folders are never visible to another
- [x] Adding a folder the user has no access to is refused
- [x] Adding the same folder twice is idempotent rather than producing a duplicate
- [x] Removing a folder deletes no files and touches no File Provider
- [x] The app offers folder selection through the existing folder picker and shows the current set
- [x] The same set is visible from a second signed-in device — the set lives only on the server, keyed by user
- [x] The service reads no other service's collections
- [x] Covered at the gallery service's NATS boundary following the `spaces` integration test pattern — embedded NATS, MongoDB testcontainer, `fxtest` lifecycle — plus a narrow gateway test for authentication and request validation following the search test pattern

## Comments

### Implementer report — base `299d583`

New `gallery` Go module, shaped on `spaces`/`shares`: own `go.mod` (added to
`go.work`), `main.go` with the same `fx` module list, `tracing.serviceName` and
`mongo.db` (`seraph-gallery`) decorators, and service-discovery announcement.
`gallery/gallery/` holds `entities.go`, `messages.go`, `migrations.go` plus the
JSON migration, and `gallery.go` with `Params`/`Result` and a single queue
subscription on `seraph.gallery.sourcefolder.crud` carrying `LIST`/`ADD`/`REMOVE`.

Only one collection, `gallerySourceFolders`, keyed uniquely on
`(userId, spaceProviderId, path)` with a second index on `userId` for listing.
Folders are stored in Space terms exactly as picked; nothing is translated to
physical coordinates. The service touches no other service's collections — its
only outbound call is `SpaceResolveRequest`.

Access control is that resolve: `ADD` resolves `(userId, spaceProviderId)`
against `spaces` and refuses the folder when resolution comes back empty, which
is how `spaces` reports both "no such space" and "not yours". Every operation
filters on `userId`, including `REMOVE`, so one user cannot remove another's
folder by guessing its id. Idempotency is an upsert with `$setOnInsert` on the
unique key rather than an insert-then-catch. `REMOVE` deletes one configuration
document and does nothing else; a test subscribes to `seraph.>` and asserts no
message leaves the service during a remove.

api-gateway gains `api-gateway/gallery/gallery.go` registered in `main.go`:
`GET`/`POST` `/api/gallery/source-folders` and
`DELETE /api/gallery/source-folders/:sourceFolderId`, all under the authenticated
`apiGroup`. The user id always comes from the session and a client-supplied
`userId` in the body is ignored.

App side reuses the file browser's own `FileService.readDir` for the picker
(`folder_picker_dialog.dart`), so the user browses the same tree with the same
listing code; the first path segment is the space provider and the remainder is
the path within it. `gallery_view.dart` replaces the "coming soon" placeholder
with the current set plus add and remove.

Deployment wiring added alongside the code: `Dockerfile` build and copy lines,
and a `gallery` service in both `docker-compose.yml` and
`docker-compose.dev.yml`. Without these the service could not actually run.

**Tests:** six gallery-service tests against embedded NATS and a real MongoDB
testcontainer (list/add/remove, idempotency including trailing-slash, refusal
without access, per-user scoping, no-side-effect remove, request validation), and
five gateway tests following the search pattern (authenticated user id, ignoring
client-supplied user id, request validation, refusal mapping, remove). All pass.
`flutter analyze` was **not** run — no Flutter or Dart toolchain is installed on
this machine, so the Dart changes are unverified by a compiler.

**Decisions the ticket did not settle:**

- *Error mapping.* `spaces` maps every service-side error to 500. Since the
  gateway validates the request itself, the remaining `ADD` failure is an access
  refusal, so that maps to 403 and a failed `REMOVE` maps to 404. This is a
  deliberate departure from the `spaces` handler's blanket 500.
- *Path normalisation.* Paths are `path.Clean`ed and required to be absolute, so
  `/holidays` and `/holidays/` are one folder rather than two. The ticket asks
  for idempotency without saying whether these are the same folder.
- *Message shape.* One CRUD topic with an operation field, following
  `SpaceCrudRequest`, rather than three topics — but with plain fields instead of
  an `entities.Prototype`, since there is no partial-update operation here.
- *No web UI.* The Angular app has no spaces or settings UI to extend, so folder
  selection is mobile-app only. The ticket's "the web UI see the same set" is
  satisfied by the server holding the set, not by new Angular screens.
- *Placeholder replaced.* `GalleryView` already existed as a "coming soon"
  placeholder at `/gallery`; the folder configuration went there rather than into
  a new settings screen.

### Verifier verdict — APPROVED

Independent review against the diff from `299d583`, by an agent that had not seen
the implementer's reasoning. Every criterion checked against the code rather than
the implementer's checked boxes.

- Per-user scoping enforced on LIST, ADD and REMOVE; `REMOVE` filters on `_id`
  **and** `userId`, so one user cannot remove another's folder by guessing its id.
- The access check on `ADD` is a genuine server-side resolve against `spaces`
  (`SpaceResolveRequest`), covering both space ownership and file-provider
  membership — not a gateway- or app-only check.
- Idempotency is a `FindOneAndUpdate` upsert with `$setOnInsert` against the
  unique compound index, so there is no insert-then-catch race.
- `REMOVE` performs a single `FindOneAndDelete` on the configuration collection;
  no file-deletion or File Provider code path exists in the service at all.
- Exactly one MongoDB collection is touched, confirming the service reads no
  other service's collections.
- Go build, vet and the full test suites for `gallery` and `api-gateway/gallery`
  were run and genuinely pass, against a real MongoDB testcontainer and embedded
  NATS.

**Contamination check.** A stray agent from a first, mistaken implementation
attempt had written into this worktree concurrently. The verifier was asked to
look for artifacts and found none: a single clean commit, no `.orig`/`.rej`/`.bak`
leftovers, and the file listing matches the ticket exactly.

**Environmental limitation, not a defect.** No Flutter/Dart toolchain exists on
this machine, so the five Dart files have never been seen by a compiler. They
were read by hand and are structurally sound — balanced braces, no duplicate
declarations, single route registration, response field names matching the Go
JSON tags, and `readDir`/`File.isDir`/`File.name` matching `file_service.dart`'s
actual signature. Worth a `flutter analyze` on a machine that has the toolchain.

### Follow-up — Dart changes since verified with a real toolchain

The verifier's caveat that the five Dart files had never been seen by a compiler
is now closed. The Flutter toolchain was not on `PATH`, but it exists at
`/home/vortex/Development/flutter/flutter/bin/flutter`.

`flutter analyze` over `app/seraph_app` reports **zero issues in
`lib/src/gallery/` and zero errors anywhere**. The 48 findings it does report are
all pre-existing `avoid_print`, `strict_top_level_inference` and
`depend_on_referenced_packages` infos in login, search, settings, share, the
media player and one chat test — none introduced by this ticket.

The hand review was correct. No code change needed.
