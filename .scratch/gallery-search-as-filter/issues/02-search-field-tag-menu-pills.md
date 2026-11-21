# 02 — Search field, Tag… menu and pills; delete the search screen

**What to build:** In `gallery_view.dart`:

- **Search field.** The app-bar search icon (shown only when `available == true`) switches the app bar's
  title to a `TextField`. Submitting a non-empty value calls `applyAi` with the new text and the current
  tag and person, then closes the field.
- **Tag… menu item.** A new **Tag…** item in the filter menu (AI only) opens a dialog listing
  `search.status.tags`, like `_PeopleDialog`. Picking a tag calls `applyAi`.
- **Pills.** `_FilterChipsBar` shows a removable text pill (search icon and the query; tapping it reopens
  the field with the text filled in), a removable tag pill, and the existing person pill. Each pill's
  delete action calls `applyAi` with that part cleared.
- **Analysis line.** `_FilterChipsBar` shows "Analysing photos… N left" while an `ai` pill is present and
  `status.pending > 0`.
- **Scrubber.** The date scrubber and its bubble are hidden while `filter.ranked`.

Delete `gallery_search_view.dart`, its route in `app.dart`, `GalleryPhotoViewerView.items` and its
branches, and `test/gallery/gallery_search_test.dart`. Move any of that test's cases that still apply into
`gallery_view_test.dart`.

See [spec](../spec.md).

**Acceptance:**
- Searching "sunrise" and then picking a Place filters the main grid to both.
- Tapping a result opens the viewer, and swiping moves through the filtered results.
- Removing a pill restores the previous view.
- The scrubber is hidden only while the text pill is shown.
- `gallery_view_test.dart` covers the field → pill → removal round trip, and that Tag… appears only with AI.
- Gates: `flutter analyze` with zero issues, `flutter test`, `flutter build web --release --base-href=/app/`.
- Manual check of the web build in Chrome, not the browser pane, because the drift worker hangs there.

**Blocked by:** 01

**Status:** resolved
