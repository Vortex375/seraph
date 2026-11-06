# 02: Queue view and editing

**What to build:** From the "now playing" screen, the user opens the queue and sees every track with
the playing one highlighted and scrolled into view. They can tap a track to play it, drag tracks to
reorder, and swipe a track away to remove it. The playing track keeps playing through moves and
through removals of other tracks. Removing the playing track continues with the next one. Removing the
last track closes the player.

This ticket also introduces the pure **queue model** and the handler's queue-edit operations. Ticket 03
(enqueue) reuses them. See "Queue model and editing (app)" in `../spec.md`.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

- [ ] A pure Dart queue model (no Flutter, GetX or just_audio imports) implements `append`, `playNext`, `move`, `removeAt` and `replace`. Each returns the new entry list and current index, following the rules in the spec.
- [ ] The `audio_service` handler applies model operations to both its `queue` and the just_audio playlist incrementally (`addAudioSources` / `insertAudioSources` / `moveAudioSource` / `removeAudioSourceAt`). The playing track is not reloaded by a move, or by an insert or removal of another entry.
- [ ] They are exposed through `addQueueItems`, `insertQueueItem`, `removeQueueItemAt` and a custom move action. The controller offers matching methods.
- [ ] The file viewer's Play button goes through `replace`, and its behaviour is unchanged.
- [ ] Removing the playing entry advances to the next entry (or the new last entry). Emptying the queue stops the player and dismisses the notification.
- [ ] The queue view opens from "now playing". It is a reorderable list with a drag handle per row, swipe to dismiss, tap to jump, the playing row highlighted, and an initial scroll to the playing row. Rows show the file name for now (ticket 04 adds tags).
- [ ] Next and previous (in-app, notification and lock screen) follow the edited order.
- [ ] Unit tests cover the queue model cases listed under Testing Decisions in the spec.
- [ ] Gates: `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`.
