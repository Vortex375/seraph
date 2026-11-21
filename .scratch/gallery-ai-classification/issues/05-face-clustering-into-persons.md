# 05 — Group faces into Persons

**What to build:** Port Immich's incremental clustering (`server/src/services/person.service.ts`,
`handleRecognizeFaces`) as described in spec "People clustering": `maxDistance` (default 0.5) and
`minFaces` (default 3) in config; core/non-core faces; non-core faces are marked `deferred` once and
reprocessed by a periodic pass that runs when the consumer is idle; join the nearest Person, else create one for a core face; global lock. Runs
after each photo's faces are stored (ticket 03). A Person left with no faces is deleted; a Person whose
cover face is deleted gets another of its faces as cover. Faces with `manual = true` are skipped as
input but count as neighbours (spec "People clustering").

**Blocked by:** 03

**Status:** ready-for-agent

- [ ] Three near-identical face embeddings in three photos form one Person; a fourth joins it.
- [ ] A single isolated face stays unassigned.
- [ ] A non-core face near an existing Person is assigned on its deferred pass.
- [ ] Two well-separated clusters form two Persons.
- [ ] Faces with `manual = true` are never reassigned, but count as matches and lend their Person to
      nearby new faces.
- [ ] Deleting all photos of a Person deletes the Person; deleting its cover photo moves the cover.
- [ ] Gates: `go test ./...` in `gallery-ai`.
