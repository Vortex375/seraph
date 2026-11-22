# Gallery search as a filter

Status: ready-for-agent

Phase: specification. Decided in conversation on 2026-11-21. Tickets in `issues/`.
Supersedes the app half of [gallery-ai-classification ticket 08](../gallery-ai-classification/issues/08-app-gallery-search.md).

Vocabulary: [CONTEXT.md](../../CONTEXT.md)

## Problem Statement

AI search has its own screen (`GallerySearchView`) with its own grid. This causes three problems:

- Search can't be combined with the other filters. "Sunrise" plus a Place or a date range isn't possible.
- Search results are a dead end. Tapping a result opens the viewer only on that result list, with no way
  back into the gallery around the photo.
- The screen duplicates the main grid: its own tiles, its own empty state and its own viewer wiring.

## Solution

Search becomes part of `GalleryFilter`, like Place and People. The search screen is deleted.

- **Free text** is typed into a search field in the Gallery app bar. Submitting the field adds a text pill
  to `_FilterChipsBar`.
- **Tag** is chosen from a new **Tag…** item in the filter menu, in a dialog listing
  `analysisStatus().tags`, the same way **People…** works. The tag shows as its own pill.
- **Person** works exactly as it does now, but goes through the same mechanism.
- Each pill can be removed on its own. The filter badge counts text, tag and person separately.
- The main grid, the count, the selection and the viewer all work on the filtered list unchanged, because
  they already read through `GalleryFilter`.

### One AI part of the filter

Text, tag and person are all answered by the same server call, `GET gallery/search?q=&tag=&person=`, and
the server already combines them. They therefore share one filter part, which replaces `GalleryPersonFilter`:

```dart
class GalleryAiFilter {
  final String? text;
  final String? tag;
  final GalleryPerson? person;      // for the pill's avatar
  final List<(String, String)> keys; // Space keys of the hits
}
```

Whenever any of the three changes, `GallerySearchController` sends **one** search request with all of the
non-null parts, using `limit: 1000` (the current maximum). It then sets
`grid.setFilter(filter.copyWith(ai: …))`. When all three are cleared, `ai` becomes null.

Combining the parts on the server matters. "Sunrise" plus Anna returns the top 1000 sunrise photos *of
Anna*, not the top 1000 sunrise photos with Anna's photos picked out afterwards.

### Ordering: date by default, relevance on request

Revised twice. The first version always sorted text search best match first; the second always kept
Capture Date. The final rule (2026-11-22) offers both:

- While a text pill is shown, a **sort-order pill** sits next to it: "Newest first" (the default) or
  "Best match". Tapping it toggles. It needs no new search: `ai.keys` are already in score order.
- `GalleryAiFilter.byRelevance` holds the choice; `GalleryFilter.ranked` is
  `ai.text != null && ai.byRelevance`, read by the mirror (order), the grid controller (no month
  boundaries) and the view (no date heading or scrubber).
- The choice survives the tag or person changing. Removing the text pill removes the sort pill and
  goes back to date order; a later text search starts at "Newest first".
- The sort pill isn't counted in the filter badge.

Text search has no "no match": it returns the N nearest photos. In date order, weak matches would mix in
with good ones, so `gallery-ai` drops text hits below a minimum cosine similarity,
`gallery.ai.search.minScore` (env `SERAPH_GALLERY_AI_SEARCH_MINSCORE`), in both orders. It applies to text
only; tag and person are exact membership already.

- `ponytail:` the default 0.23 is a guess for CLIP ViT-B/32 bare queries, next to the tags' 0.25 for
  "a photo of …" prompts. Tune it against real photos, and again when the CLIP model changes.

### Mirror

- `_filterPredicate`: the existing person clause (`_InJsonArray` over `providerId\u001fpath`) becomes the
  `ai` clause, unchanged apart from where it reads the keys.
- `queryPage`/`queryItems`: when `filter.ranked`, sort by
  `(SELECT key FROM json_each(?) WHERE value = provider_id || '\u001f' || path)` (the `json_each` key is the
  array index), then `id DESC`, instead of `capturedAt DESC, id DESC`. The keys are bound as one JSON
  array, so the 999-variable limit never applies.

## User Stories

1. As a user, I can search for "sunrise" and then filter by a city, and see only sunrise photos from that
   city.
2. As a user, my search shows up as a pill that I can remove, which brings back the previous view.
3. As a user, I can tap a search result to see it full screen, and swipe through the other results.
4. As a user, text search results appear newest first, without photos that barely match, and I can
   switch them to best match first.
5. As a user, I can combine text, a tag and a person, and remove each one separately.

## Implementation Decisions

- `GalleryPersonFilter` becomes `GalleryAiFilter`. `GalleryFilter.person` becomes `GalleryFilter.ai`, and
  `copyWith` changes to match (`ai:` / `clearAi:`). `activeCount` counts text, tag and person
  separately.
- `GallerySearchController` keeps `available`, `people`, `status`, `probe`, `loadChips`, `renamePerson` and
  `assignFace`. Its `results`/`searching`/`searched`/`text`/`tag`/`search()`/`setTag()` are deleted.
  `filterByPerson` becomes `applyAi(grid, {text, tag, person})`. The caller passes the full new
  combination, read from the current `grid.filter.value.ai` and changed in one place. It returns false on
  failure and leaves the filter as it was, as `filterByPerson` does.
- Removing a pill calls `applyAi` with that part cleared. If nothing is left, it calls
  `grid.setFilter(filter.copyWith(clearAi: true))` without a request.
- While `applyAi` is in flight, the grid shows its normal loading state. A newer request supersedes an
  older one using the existing `_generation` pattern.
- The app-bar search icon, shown when `available == true`, switches the app bar's title to a `TextField`.
  Submitting a non-empty value calls `applyAi` and closes the field. Tapping the text pill reopens the field
  with its text filled in.
- The "Analysing photos… N left" line moves from the search screen into `_FilterChipsBar`. It shows while
  an `ai` pill is active and `status.pending > 0`, because that is when results are incomplete.
- The existing listener that clears the person filter when AI becomes unavailable clears the whole `ai` part.
- Deleted: `gallery_search_view.dart`, its route in `app.dart`, `GalleryPhotoViewerView.items` and its
  branches (its only caller was the search screen), and `test/gallery/gallery_search_test.dart`.

## Testing Decisions

- Mirror (unit, in-memory DB): an `ai` key set is membership in Capture Date order, intersected with the
  other filters. A key set above 999 still works.
- `gallery-ai` (integration): text hits below `SearchMinScore` are dropped; searches without text are not
  affected.
- `GallerySearchController.applyAi` with a fake `GalleryService`: one request containing every part. On
  failure the filter is unchanged. A newer call wins over a slower older one.
- `gallery_view_test.dart`: submitting the search field shows a text pill and filters the grid. Removing
  the pill restores the grid. The Tag… menu item appears only when AI is available.
- Gates (AGENTS.md): `flutter analyze` must report zero issues, `flutter build web --release --base-href=/app/`
  must succeed, and `flutter test` must pass. `android/` isn't touched, so the APK build isn't required.

## Out of Scope

- Sending Place or date filters to the server.
- Paging past 1000 results.
- Keeping the search in the URL across a reload. The filter isn't in the URL today either.
- Server changes beyond the `gallery-ai` score cutoff, and the web app.

## Known ceilings

- `ponytail:` text and person results are capped at 1000 server-side (`MaxSearchLimit`). They're then
  intersected locally with Place, date and Availability, so a narrow local filter on a large library can
  hide matches beyond the first 1000. Fix later by sending the local filter's Space keys to the server,
  or by paging.
- The key set is a snapshot taken when the pill was set. Photos analysed later won't appear until the pill
  is set again, the same as the person filter today.
