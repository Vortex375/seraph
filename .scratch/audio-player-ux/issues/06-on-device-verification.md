# 06: On-device verification

**What to build:** The acceptance pass on a real Android device and in a browser. It confirms the seek
bar, queue editing, enqueue, metadata and album art behave as the spec describes in real use, including
the system notification and lock screen, which no automated test covers. It needs a phone and judgement
on look and feel, so it is for a human.

**Blocked by:** 01: Material 3 seek bar; 02: Queue view and editing; 03: Enqueue from the file browser; 04: Track metadata end to end; 05: Album art end to end

**Status:** ready-for-human

- [ ] Seek bar: it has the new Material 3 look. The buffered track grows ahead of the thumb. Dragging scrubs without stutter and seeks on release. The mini player progress has the new look.
- [ ] Queue: it opens scrolled to the playing track. Tapping jumps. Dragging the playing track and other tracks keeps playback uninterrupted. Swiping the playing track continues with the next one. Swiping the only track closes the player. Lock-screen next and previous follow the edited order.
- [ ] Enqueue: Play next and Add to queue on a file, on a multi-selection with non-audio files mixed in, and on an album folder (correct track order). Enqueuing with the player closed starts playback. The snackbar counts are right. The file viewer's Play still replaces the queue.
- [ ] Metadata: a tagged MP3, FLAC and M4A each show title, artist, album, year, track number and genre on "now playing", and title and artist in the mini player and queue. An untagged file shows its file name. The notification and lock screen show title, artist and album.
- [ ] Album art: embedded art shows. A folder with only `cover.jpg` shows art. A track with no art shows the placeholder. A file with a large (multi-MB) embedded cover shows art. The notification and lock screen show art.
- [ ] Web (`/app/` release build): the same checks for seek bar, queue, enqueue, metadata and art. A share link to an album folder shows metadata and art.
- [ ] Compose deployment: `audio-metadata` runs, and the logs show no TagLib or library-loading errors.
