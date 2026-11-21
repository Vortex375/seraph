# 09 — App: People screen

**What to build:** A People screen reachable from Gallery Mode: grid of Persons (face crop drawn from the
cover photo's Thumbnail and normalised box, name or "Unnamed", photo count), rename dialog
(`PATCH gallery/people/:id`), tap → that Person's photos (`GET gallery/search?person=`). Hidden when the
server answers `ai-unavailable`.

**Blocked by:** 07, 08

**Status:** resolved

- [x] Face crops show the face, not the whole photo, at grid size.
- [x] Renaming updates the grid and the Person chip in search.
- [x] Tapping a Person shows their photos.
- [x] Gates: `flutter analyze` zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.

## Comments

2026-11-21 (coordinator): Gates passed. Face-crop rendering is only covered via the crop-math unit tests; check it by eye on real faces.
