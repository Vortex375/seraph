# 02 — Admin-only jobs API

**What to build:** Per spec "Jobs API":

- `api-gateway/jobs/jobs.go`: inject `auth.Auth`; `GET /api/jobs` returns 403 unless `IsSpaceAdmin`.
- Entries carry the new `JobEvent` fields (they follow from the regenerated struct's camel JSON tags) plus
  `time`.
- Skip and log KV entries whose bytes do not unmarshal, instead of returning them half-decoded.

**Blocked by:** 01

**Status:** resolved

- [x] A non-admin user gets 403; an admin (and no-auth mode) gets 200.
- [x] Each entry has `key`, `description`, `statusMessage`, `state`, `done`, `total`, `pending`, `time`.
- [x] An entry written with the pre-01 schema is left out of the list and logged; the request still
      returns 200 with the other entries.
- [x] An empty bucket returns `[]`, not `null`.
- [x] Gates: `go test ./...` in `api-gateway`.
