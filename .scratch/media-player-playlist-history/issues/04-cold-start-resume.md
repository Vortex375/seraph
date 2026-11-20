# 04: Cold-start resume and Android media resumption

**What to build:** Idle resume also works when the app process was dead: a headset or Bluetooth play
button, or Android's media-resumption card, starts the app via `audio_service` and resumes the most
recent playlist. `main()` creates the handler before `LoginController`, so the resume must wait until
the saved login session is restored before loading authenticated sources. The handler answers the
recent root (`AudioService.recentRootId`) with the current entry so the resumption card shows and plays
it. See "Idle play and cold start" in `../spec.md`. This is the main risk of the feature: confirm the
token timing on a device early.

**Blocked by:** 03: Idle play resumes the most recent playlist

**Status:** ready-for-human

- [x] A play command arriving before `LoginController` has restored its session waits for it instead of failing on missing auth. If no session can be restored (logged out), it does nothing.
- [x] The handler answers the recent root with the current history entry, and play / `playFromMediaId` / `prepare` from the resumption card resume it at the saved track and position.
- [x] Any change needed under `android/` (manifest, the `MediaBrowserService` declaration) is made and documented in the ticket comments.
- [ ] Verified on a device: kill the app, press a headset play button → the last playlist resumes. Kill the app, use Android's media-resumption card → it resumes.
- [x] Gates: `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`; `flutter build apk` if `android/` was touched.

## Comments

### Implementation (agent)

- **Login wait.** `LoginController.sessionRestored` (a `Completer<bool>`) settles on the first `init()`: true when a session is restored/refreshed or no auth is needed, false when none could be restored (interactive login needed, discovery failed, or no server configured). `MyAudioHandler.sessionReady` (a `Future<bool> Function()?`, unset = ready) is set by `main()` after `LoginController` exists. `_restoreCurrent` and `_playHistory` await it; false means do nothing. No sleeps or polling.
- **FileService** moved from `InitialBinding` to `main()` (registered right after `LoginController`, before `runApp`), so `mediaItemFor` has it when a cold-start play arrives.
- **Resumption.** `getChildren(AudioService.recentRootId)` returns the current entry as one playable item (`history/0`). `playFromMediaId('history/0')` already goes through `_playHistory`; `prepare()` / `prepareFromMediaId('history/0')` restore without playing, via the same shared `_restoring` future as `play()`.
- **android/: no change needed.** The manifest already declares `AudioService` with the `android.media.browse.MediaBrowserService` intent filter and `MediaButtonReceiver` with `MEDIA_BUTTON`; audio_service 0.18.19's `onGetRoot` maps `EXTRA_RECENT` to the recent root itself, and `androidResumeOnClick` defaults to true. `flutter build apk` was run anyway and succeeds.
- Tests: `test/media_player/audio_handler_history_test.dart` group "cold start".
- Open: device verification (headset play after kill; resumption card; token timing). Not ticked.

- Review fix (orchestrator): `sessionReady` in `main.dart` now also counts a live session (`currentUser` set or `isNoAuth`), so a cold start that needed an interactive login still resumes after the user logs in. It is installed only off web, where `sessionRestored` never settles and there is no cold start.
