# 09 — App: People screen

**What to build:** A People screen reachable from Gallery Mode: grid of Persons (face crop drawn from the
cover photo's Thumbnail and normalised box, name or "Unnamed", photo count), rename dialog
(`PATCH gallery/people/:id`), tap → that Person's photos (`GET gallery/search?person=`). Hidden when the
server answers `ai-unavailable`.

**Blocked by:** 07, 08

**Status:** needs-triage

- [ ] Face crops show the face, not the whole photo, at grid size.
- [ ] Renaming updates the grid and the Person chip in search.
- [ ] Tapping a Person shows their photos.
- [ ] Gates: `flutter analyze` zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.
