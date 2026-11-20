# 06: On-device verification

**What to build:** The acceptance pass on a real Android device, in Android Auto (the Desktop Head Unit
is fine) and in a browser. It confirms the history, idle resume and cold-start resume behave as the spec
describes in real use, which no automated test covers. It needs a phone and a car or DHU, so it is for a
human.

**Blocked by:** 02: Recent playlists screen; 03: Idle play resumes the most recent playlist; 04: Cold-start resume and Android media resumption; 05: Recent playlists in Android Auto

**Status:** resolved

- [x] History: play folder A, then folder B → A is archived. Play B again → no new entry. Enqueue, move and remove tracks in B → no new entry, and the edits show in B's track list. Play 12 different folders → only 10 archived, oldest dropped.
- [x] Screen: reachable from the nav dropdown with nothing playing, and from the player. Labels are readable. Expand shows tracks. Play resumes at the saved track and position and moves the entry to the top. Add to queue appends. Delete removes.
- [x] Idle resume: close the player, press play on the lock screen or headset → the playlist resumes where it stopped.
- [x] Cold start: force-stop the app, press a headset play button → it resumes. Force-stop, use the media-resumption card → it resumes.
- [x] Android Auto: both folders show. Playing a queue child and a history child both work.
- [x] A playlist with a track deleted on the server: the track shows the error and playback moves on.
- [x] Logout clears the history.
- [x] Web (`/app/` release build): the history and screen work. The history survives a reload.

## Comments
