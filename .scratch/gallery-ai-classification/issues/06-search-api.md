# 06 — Search API through gallery and the gateway

**What to build:** Per spec "User-facing APIs":

- `gallery-ai` topics `seraph.gallery.ai.search` and `seraph.gallery.ai.status`, filtered by the
  request's physical prefixes (escaped `LIKE`). Search: `text` ranks by cosine distance to its text
  embedding (one `/predict` call per query); `tag` and `personId` filter; no `text` → newest `seq` first;
  `limit` default 200, max 1000.
- Gallery topics `seraph.gallery.search` and `seraph.gallery.analysis.status`: resolve the user's
  folders (`resolveFoldersForUser`), pass physical prefixes, translate results with `translate`, drop
  untranslatable rows, return `error: "ai-unavailable"` when `gallery-ai` does not answer.
- Gateway: `GET gallery/search?q=&tag=&person=&limit=`, `GET gallery/analysis/status`.

**Blocked by:** 03, 04 (tag filter), 05 (person filter)

**Status:** ready-for-agent

- [ ] A user gets results only from photos under their own Gallery Source Folders; another user's photos
      never appear, even when they match better.
- [ ] Results carry Space coordinates that `GET preview` accepts.
- [ ] `q`, `tag` and `person` combine (AND).
- [ ] A path prefix containing `%` or `_` does not match sibling folders.
- [ ] With `gallery-ai` stopped, the gateway answers with the `ai-unavailable` error, not a 500 hang.
- [ ] Gates: `go test ./...` in `gallery-ai`, `gallery`, `api-gateway`.
