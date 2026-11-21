# 08 — App: search in Gallery Mode

**What to build:** A search entry in Gallery Mode (Flutter app): free-text field, tag chips, Person chips
(from `GET gallery/people`). Calls `GET gallery/search`, joins the returned Space keys to mirror rows and
shows them as a grid in score order, opening the existing viewer. Shows analysis progress from
`GET gallery/analysis/status` while photos are still pending. Hidden when the server answers
`ai-unavailable`. Device-only photos are not part of results.

**Blocked by:** 06

**Status:** needs-triage

- [ ] Typing a query shows matching photos in score order; tapping opens the viewer.
- [ ] Tag and Person chips narrow the results and combine with the text.
- [ ] A result with no mirror row yet (not synced) is skipped, not shown as a broken tile.
- [ ] Search is hidden when the server reports `ai-unavailable`.
- [ ] Gates: `flutter analyze` zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.
