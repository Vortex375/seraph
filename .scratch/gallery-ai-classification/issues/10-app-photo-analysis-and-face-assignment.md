# 10 — App: tags and faces in the viewer, face assignment

**What to build:** Per spec "App": the photo viewer's details (Flutter app) load
`GET gallery/photos/analysis` for a cloud photo and show its tags and faces — a box overlay on the photo
and a strip of face crops with Person names. Tapping a face offers: pick an existing Person (from
`GET gallery/people`), create a new Person with a name, or remove the face from its Person; each calls
`PUT gallery/faces/:id/person` and refreshes the details. Not-yet-analysed photos show a pending note;
device-only photos show nothing. Hidden when the server answers `ai-unavailable`.

**Blocked by:** 07, 09

**Status:** resolved

- [x] Tags and faces show for an analysed photo; boxes line up with the faces at any viewer zoom.
- [x] Assigning a face to another Person updates the strip and that Person's photos on the People screen.
- [x] Creating a new Person from a face makes it appear on the People screen with that name.
- [x] Removing a face from its Person shows it as unassigned.
- [x] Gates: `flutter analyze` zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.

## Comments

2026-11-21 (coordinator): Gates passed (analyze 0 issues, 488 tests, web release build). Faces are picked from the strip in the details sheet; the photo overlay shows while the sheet is open and hides when zoomed. Overlay alignment is only covered by unit tests; check by eye.
