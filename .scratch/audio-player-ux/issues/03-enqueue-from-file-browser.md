# 03: Enqueue from the file browser

**What to build:** In the file browser, the user can send an audio file, a selection or a folder to the
queue with **Play next** or **Add to queue**. A folder adds its own audio files, not subfolders, in name
order. Non-audio files in a selection are ignored. If nothing is playing, enqueuing starts playback
with the added tracks. A snackbar confirms how many tracks were added. The file viewer's Play button
still replaces the queue. See "Enqueue from the file browser (app)" in `../spec.md`.

**Blocked by:** 02: Queue view and editing (uses the queue model and handler operations)

**Status:** resolved

- [x] An audio file's per-item menu in list view and in grid view offers "Play next" and "Add to queue".
- [x] A folder's per-item menu offers the same two entries. They add the folder's audio files from one non-recursive listing (`readDir` + `isAudioFile`), sorted by name, natural order if cheap.
- [x] Selection mode's app bar offers both actions for the selected audio files and the audio files of selected folders. The actions are hidden or disabled when the selection has none. Selection mode ends after the action.
- [x] With an empty queue or a closed player, either action starts playback at the first added track.
- [x] "Play next" inserts after the playing track; "Add to queue" appends. Both use the queue model from ticket 02, and the playing track is not interrupted.
- [x] A snackbar reports the number of tracks added. It says when a folder or selection had no audio files.
- [x] Works in share mode (web share link) as well as for the user's own Spaces.
- [x] Gates: `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.

## Comments

Implemented in `644c81b` (+ review fixes in `ac5c8c5`):
`FileBrowserController.enqueue` expands folders and drops non-audio files;
`AudioPlayerController.enqueue` inserts/appends and starts playback when
nothing is playing. Plain name order (the spec allows it over natural sort).
Grid view gets a per-tile overflow menu. Skipped: hiding the actions for
selected folders that turn out to be empty (only knowable after listing) -
the snackbar covers it.
