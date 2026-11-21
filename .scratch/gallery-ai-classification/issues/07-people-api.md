# 07 — People, photo analysis and face assignment API

**What to build:** Per spec "User-facing APIs" and "Manual face assignment":

- `gallery-ai` topics `seraph.gallery.ai.people`, `seraph.gallery.ai.person.rename`,
  `seraph.gallery.ai.photo` (tags + faces of one photo), `seraph.gallery.ai.face.assign`.
- Gallery fronting topics `seraph.gallery.people`, `seraph.gallery.people.rename`,
  `seraph.gallery.photo.analysis`, `seraph.gallery.faces.assign` (same resolve/translate pattern as
  ticket 06).
- Gateway routes `GET gallery/people`, `PATCH gallery/people/:id`,
  `GET gallery/photos/analysis?providerId=&path=`, `PUT gallery/faces/:id/person` with exactly one of
  `{"personId": "…"}`, `{"newPersonName": "…"}`, `{"personId": null}`.

People are installation-wide, but each user's list contains only Persons with at least one face in a
photo the user can see, and `photoCount` counts only those photos. The cover is a visible face. Rename and
assignment are allowed only for faces and Persons visible to the caller.

Assignment sets `faces.person_id` and `faces.manual = true` under the clustering lock; a Person left
without faces is deleted, a moved-away cover face is replaced, a new Person's cover is the assigned face.

**Blocked by:** 04, 05

**Status:** resolved

- [x] A Person who appears only in photos outside the caller's folders is not listed and cannot be
      renamed or assigned to by them.
- [x] `photoCount` and the cover reflect only the caller's visible photos.
- [x] `GET gallery/photos/analysis` returns tags with scores and faces with id, normalised box, Person and
      `manual` for a photo given by Space coordinates; a not-yet-analysed photo answers `analysed: false`.
- [x] Assigning a face to another Person moves it and sets `manual`; the old Person is deleted if empty.
- [x] `newPersonName` creates a Person with that name and this face as cover.
- [x] Unassigning leaves `person_id` NULL; a later clustering pass does not reassign it.
- [x] A body with none or more than one of the three fields is rejected with 400.
- [x] Assigning a face in a photo the caller cannot see is rejected.
- [x] Gates: `go test ./...` in `gallery-ai`, `gallery`, `api-gateway`.
