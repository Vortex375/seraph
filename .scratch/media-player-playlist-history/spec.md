# Media player: playlist history and idle resume

Status: resolved

Builds on `.scratch/audio-player-engine/` and `.scratch/audio-player-ux/` (just_audio + `audio_service`,
queue model, queue view, enqueue from the file browser). Both have landed.

## Problem Statement

The player forgets everything once its queue is replaced:

- Pressing Play in the file viewer throws away the queue that was playing. There's no way back to it
  short of rebuilding it by hand.
- The player is reachable only while something is playing, so there's nowhere to pick up an earlier
  listening session.
- A "play" command from Android Auto, a Bluetooth headset, the lock screen or Android's media-resumption
  card does nothing when no media is loaded, including after the app process was killed. Other music
  apps resume the last thing that played.

## Solution

- The app keeps a **playlist history** on the device: the **current playlist** plus up to **10 archived
  playlists**, newest first. A history entry stores its tracks, the current track index, the position
  in that track and when it was last played.
- **Only a full replace of the queue starts a new playlist.** That is
  `AudioPlayerController.setPlaylist` (the file viewer's Play button, picking a history entry). The
  current playlist moves to the top of the archive. If the archive already holds 10, the oldest entry is
  dropped.
- **Edits change the current playlist in place.** Play next, Add to queue, moving a track and removing a
  track update the current entry. They don't archive anything.
- **An identical replace doesn't archive.** If the new track list is exactly the same as the current one
  (same paths in the same order), nothing is archived. The current entry only takes the new index and
  position. This stops one album from filling every slot.
- **The resume point is saved continuously.** The current entry's index and position are saved on
  pause, stop and track change, and periodically while playing.
- **Closing the player keeps the playlist.** The bottom bar's close button, and emptying the queue by
  removing every track, stop playback. The current entry stays as the last saved snapshot.
- **Idle play resumes.** When the handler gets `play()` with an empty queue, it loads the current
  history entry and resumes at its saved track and position. This also works on a **cold start** after
  the app process was killed.
- A **Recent playlists** screen lists the current playlist and the archive. It is reachable from:
  - the app bar's navigation dropdown (next to Files, Gallery, ...),
  - the "now playing" / queue view,
  - an Android Auto browse folder.
- Each row is labeled automatically from its contents. Tapping a row shows its track list. Each entry
  can be **played** (replaces the queue), **enqueued** (appends to the current queue) or **deleted**.
- **Playing an archived entry moves it to the top.** It leaves the archive and becomes current, and the
  previous current playlist is archived. There are no duplicates, so the list works like recently-used.
- **Logout clears the history.** There is one global list per device.

## User Stories

1. As a listener, I want pressing Play on a new folder to keep my previous queue in a history, so that I can return to it later.
2. As a listener, I want adding, removing and reordering tracks to change the current playlist and not start a new history entry, so that the history isn't cluttered with every edit.
3. As a listener, I want the history to hold my 10 most recent earlier playlists, so that recent sessions are kept without unbounded growth.
4. As a listener, I want pressing Play on the folder that's already playing to not add a duplicate history entry, so that one album doesn't fill the history.
5. As a listener, I want to open a Recent playlists screen from the navigation menu even when nothing is playing, so that I can start an earlier session.
6. As a listener, I want to open the history from the player, so that I can switch to an earlier playlist while listening.
7. As a listener, I want each history entry to have a readable label (folder or first track, track count, how long ago), so that I can recognise it.
8. As a listener, I want to expand a history entry to see its tracks, so that I know what I'm about to play.
9. As a listener, I want playing a history entry to continue at the track and position where it stopped, so that I can pick up where I left off.
10. As a listener, I want a playlist I pick from the history to move to the top and the playlist that was playing to be archived, so that nothing I was listening to is lost.
11. As a listener, I want to append a history entry's tracks to the current queue, so that I can combine sessions.
12. As a listener, I want to delete a history entry, so that I can drop playlists I don't care about.
13. As a listener, I want pressing play in Android Auto, on a headset or on the lock screen with nothing loaded to resume my most recent playlist, so that I don't have to open the app.
14. As a listener, I want that to work after the app was killed, so that the headset button and Android's media-resumption card behave like other music apps.
15. As a listener, I want closing the player to keep my playlist as the most recent one, so that the next play resumes it.
16. As a driver, I want a Recent playlists folder in Android Auto, so that I can start an earlier playlist from the car.
17. As a listener, I want a track that no longer exists on the server to be skipped with the existing error, so that one missing file doesn't block the playlist.
18. As a user, I want logging out to clear the playlist history, so that the next user of the device doesn't see my files.

## Implementation Decisions

### History model (app)

- A pure Dart **history model**, next to `queue_model.dart` and with the same "no Flutter, GetX or
  just_audio" rule, owns the current entry and the archive. Its operations each return a new state:
  - `replace(newEntry)`: archives the current entry (if any) at the top and caps the archive at 10. If
    the new track list equals the current one, it only updates the index and position.
  - `updateCurrent(paths, index, position)`: an edit or a resume-point save.
  - `promote(archiveIndex)`: the picked entry becomes current and the previous current entry is
    archived at the top.
  - `delete(archiveIndex)`.
- A history entry: `paths` (the file paths, the same values `setPlaylist` and `enqueue` take today, not
  the URL-based `MediaItem.id`), `index`, `positionMs`, `lastPlayed` (epoch ms). It is serialised to JSON.
- The model is the test seam (see Testing Decisions).

### Persistence (app)

- Stored with `get_storage` (already a dependency) under one key holding `{current, archive}` as JSON.
  The data is small (at most 11 path lists), so it's rewritten on every change.
- `LoginController`'s logout path erases the key.
- The resume point is saved on pause, stop, track change and every ~10 s while playing. Saving on
  position ticks alone isn't enough: a killed process loses at most the last interval, which is
  acceptable.

### Wiring into the player (app)

- `setPlaylist` calls `replace`. `enqueue`, `move` and `removeAt` call `updateCurrent` with the queue
  after the edit. These are the only queue-changing entry points in `AudioPlayerController`.
- Removing the last remaining track doesn't touch the history: the stored entry keeps its last
  non-empty snapshot. The same goes for `closePlayer` / `stop()`.
- Restoring an entry means `updateQueue` + `skipToQueueItem(index)` + `seek(position)`. That is the
  existing `setPlaylist` path plus a seek, so missing tracks fail through the existing per-track error
  handling and playback skips them. Nothing is validated upfront.

### Idle play and cold start (app, Android)

- `MyAudioHandler.play()`: if the queue is empty, load the current history entry (restore as above),
  then play. If there's no history either, do nothing, as today.
- The handler must be able to restore without the controller. The history store and the restore logic
  live where the handler reaches them (the handler or a small store it owns). The controller and the
  history screen go through the handler.
- **Cold start.** `audio_service` starts the Flutter engine and runs `main()` when a media-button or
  media-resumption intent arrives while the process is dead. `main()` initialises the handler before
  `LoginController`, so the handler may get `play()` before a token exists. The resume must wait for
  the login controller to finish restoring its session from `flutter_secure_storage`, or for its first
  authenticated request to succeed, before loading sources. This has to be confirmed on a device: it is
  the main risk of this feature.
- Android media resumption: the handler answers `getRecent` / the recent root (`audio_service`'s
  `AudioService.recentRootId`) with the current history entry, so Android's resumption card and
  `onPlayFromMediaId` / `prepare` from that card resume it. Check whether `android/` (manifest, the
  `MediaBrowserService` declaration) needs changes. If it does, the APK build gate applies.

### Recent playlists screen (app)

- A new route, added to the app bar's navigation dropdown (`_buildDropdown` in `app_bar.dart`) as
  "Recent playlists", and opened from a history button in the "now playing" / queue view.
- The list shows the current entry first (marked as current), then the archive.
- **Label:** the parent folder's name when all tracks share one folder, otherwise the first track's
  title / file name. Then "· N tracks · <relative time>". No renaming.
- Tapping a row expands it to its track list (file names, or tags where `ensureTags` already has them;
  no extra tag fetching is required).
- Row actions: **Play** (`promote` + restore + play), **Add to queue** (`enqueue(paths, playNext: false)`,
  which counts as an edit of the current playlist), **Delete** (swipe or menu; not offered on the
  current entry).

### Android Auto browse tree (app)

- The root (`AudioService.browsableRootId`) gets two browsable folders: **Current queue** (today's
  `queue/<i>` children) and **Recent playlists** (one playable child per history entry, id
  `history/<i>`). `playFromMediaId('history/<i>')` promotes and plays that entry.
- `subscribeToChildren` notifies the history folder when the history changes, as it already does for
  the queue.

## Testing Decisions

- **History model unit tests** (`flutter test`), in the style of the queue model tests:
  replace archives the current entry; the cap of 10 drops the oldest; an identical replace doesn't
  archive but takes the new index and position; promote moves the entry to the top and archives the
  previous current; delete; an empty history; JSON round trip.
- **Not unit-tested:** the screen, the handler's just_audio and `audio_service` calls, and cold start.
  These are verified on a device:
  - Play a folder, play another, check the history.
  - Kill the app, press the headset play button and the resumption card, and confirm it resumes at
    the saved position.
  - Android Auto (DHU): both folders, and playing a history entry.
- **Gates:** `flutter analyze` with zero issues, `flutter test`,
  `flutter build web --release --base-href=/app/`, and `flutter build apk` if `android/` is touched.

## Out of Scope

- Server-side or cross-device history sync.
- Per-account history; the history is cleared on logout instead.
- Named or renamable saved playlists.
- Validating tracks against the server before restoring.
- Video playback history.
- Real file browsing in Android Auto (still only the queue and the history).

## Further Notes

- The history stores file paths, not `MediaItem`s, so tag metadata and album art are re-derived on
  restore through the existing `ensureTags` path.
- Web: `get_storage` uses local storage there. Cold start and Android Auto don't apply on web, but the
  screen and the nav entry do.
