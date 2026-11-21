# 10 — App: tags and faces in the viewer, face assignment

**What to build:** Per spec "App": the photo viewer's details (Flutter app) load
`GET gallery/photos/analysis` for a cloud photo and show its tags and faces — a box overlay on the photo
and a strip of face crops with Person names. Tapping a face offers: pick an existing Person (from
`GET gallery/people`), create a new Person with a name, or remove the face from its Person; each calls
`PUT gallery/faces/:id/person` and refreshes the details. Not-yet-analysed photos show a pending note;
device-only photos show nothing. Hidden when the server answers `ai-unavailable`.

**Blocked by:** 07, 09

**Status:** needs-triage

- [ ] Tags and faces show for an analysed photo; boxes line up with the faces at any viewer zoom.
- [ ] Assigning a face to another Person updates the strip and that Person's photos on the People screen.
- [ ] Creating a new Person from a face makes it appear on the People screen with that name.
- [ ] Removing a face from its Person shows it as unassigned.
- [ ] Gates: `flutter analyze` zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.
