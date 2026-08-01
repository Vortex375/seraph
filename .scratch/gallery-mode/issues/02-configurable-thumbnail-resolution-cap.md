# 02 — Raise and make configurable the thumbnail resolution cap

**What to build:** A person with a recent phone should get thumbnails for their
highest-resolution photos like any other. Today the thumbnailer rejects any
image whose dimensions exceed 8120 pixels outright, so a 108 MP photo
(12000×9000) or Samsung's 200 MP mode (16320×12240) becomes a broken tile —
exactly the photos a user most wants to see.

The cap legitimately bounds decode memory, so it stays; its current value is
simply wrong for phones shipping today. Raise the default and make the limit
configurable so an administrator can trade memory against coverage on their own
hardware.

**Blocked by:** None — can start immediately.

**Status:** resolved

- [x] The maximum thumbnailable width and height are read from configuration, with a documented default well above current flagship phone resolutions
- [x] An image within the new cap that the old cap rejected now produces a thumbnail
- [x] An image beyond the configured cap is still refused, with a clear reason rather than a generic failure
- [x] The refusal reason is distinguishable by callers from "this format is not supported" and from "this file is corrupt"
- [x] Covered by the existing thumbnailer tests with fixtures at both sides of the boundary

## Comments

### Implementer report — base `e6d153f`

**Files changed:**

- `thumbnailer/thumbnailer/thumbnailer.go` — replaced the `MaxImageWidth`/
  `MaxImageHeight` consts with `Options.MaxImageWidth`/`MaxImageHeight`, defaulted
  in `NewThumbnailer` when zero. New `DefaultMaxImageWidth`/`DefaultMaxImageHeight`
  = 20000×20000. Added `ErrorClassTooLarge`, `ErrorClassUnsupportedFormat` and
  `ErrorClassCorrupt`, set on the new `ThumbnailResponse.ErrorClass` field
  depending on whether decode failed via `image.ErrFormat` (unsupported format) or
  another decode error (corrupt), versus the explicit dimension check (too large).
- `thumbnailer/thumbnailer/messages_schema.avsc` + regenerated `messages.go` —
  added an `errorClass` string field to `ThumbnailResponse`, mirroring the `Class`
  field on `fileprovider.IoError`, the repo's existing pattern for distinguishable
  NATS error reasons.
- `thumbnailer/main.go` — wired `thumbnailer.maxImageWidth`/`maxImageHeight` viper
  keys with defaults, matching the existing `jpegQuality`/`parallel` pattern.
- `thumbnailer/thumbnailer/thumbnailer_test.go` — tests for within/beyond a
  configured cap, an 8200×8200 fixture the old cap rejected but now succeeds, a
  static assertion the default clears flagship resolutions, plus unsupported-format
  and corrupt-file cases proving all three error classes are mutually
  distinguishable. Fixtures are generated on the fly, so no large binaries land in
  the repo.

**Decisions the ticket did not settle:** the default numeric value, and how the
"distinguishable reason" reaches the wire. Chose 20000×20000 (clears 200 MP mode
with headroom) and an `ErrorClass` string field on the Avro schema rather than a
new mechanism, since `fileprovider.IoError.Class` is the established convention.

**Noticed, out of scope:** `api-gateway/preview/preview.go` still collapses any
`resp.Error` into a generic 500 — it does not branch on `ErrorClass`, so the new
distinctions do not yet reach HTTP clients.

### Verifier verdict — APPROVED

- The cap is read end to end: `main.go` wires the viper keys into `Options`, which
  flow into the `Thumbnailer` struct and are enforced in `handleRequest` — not
  configurable in name only.
- The 20000×20000 default clears Samsung 200 MP (16320×12240) and 108 MP
  (12000×9000), asserted by `TestDefaultCapCoversFlagshipPhoneResolutions`.
- The three refusal reasons are distinguishable over the wire via the new
  `ErrorClass` field, not merely distinct log strings.
- `messages.go` confirmed genuinely regenerated: re-ran the Makefile's `avrogen`
  rule and diffed against the committed file — byte-identical, not hand-edited.
- Tests cover both sides of the boundary, plus the old hardcoded 8120 boundary,
  plus all three error classes.
- `go build ./...`, `go vet ./...` and `go test ./...` pass in `thumbnailer/`.

**Pre-existing defect, not a rework blocker:** `go test -race` fails in
`thumbnailer/` on a data race between `Thumbnailer.Stop()` and `messageLoop()`
over the `stop` channel/flag. The verifier checked out base `e6d153f` and reran to
confirm the race pre-exists this change. Tracked separately — see the note on
ticket 05, which adds a second consumer to this same lifecycle.
