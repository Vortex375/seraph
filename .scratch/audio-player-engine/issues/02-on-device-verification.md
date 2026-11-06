# 02: On-device verification

**What to build:** The acceptance pass for the new audio engine on a real Android device and in a
browser. It confirms the problem from the spec is gone: long queues no longer fail once the access
token expires. It also confirms nothing regressed (background, lock screen, video) and that battery
use improved. This needs a physical phone, real listening time and a judgement on battery, so it is
for a human.

**Blocked by:** 01: Audio playback on just_audio with token-safe streaming

**Status:** ready-for-human

- [ ] Android, OIDC server with the 5-minute token realm: queue a folder of 10+ tracks and let it play unattended for 30+ minutes. Every track starts with no "Playback error".
- [ ] Android: in a track longer than 10 minutes, wait past token expiry, then seek far ahead. Playback resumes. App logs show the 403 → refresh → retry path, not a failure.
- [ ] Android: pause for 4 minutes, then resume. Playback continues. Pause for more than 5 minutes: the player releases itself and the notification goes away.
- [ ] Android: with the screen off and the app in the background, playback continues. Lock-screen and notification play/pause/next/previous work and show title and duration. Headset/Bluetooth buttons work.
- [ ] Android: a deliberately broken item (deleted file or unsupported format) shows the error snackbar and does not hang the player. Skipping to the next item works.
- [ ] Android: video playback in the file viewer is unchanged.
- [ ] Android: battery. Play the same 1-hour queue with the screen off on the previous build and on the new build, from a similar starting charge. Note the battery drop for each (Settings → Battery usage for the app). The new build should be noticeably lower. Record the numbers in a comment below.
- [ ] Web (`/app/` release build): queue a folder and play through several tracks. Playback starts streaming promptly (no long wait while the whole file downloads). Seek and next/previous work.
- [ ] Web share link: audio in a shared folder plays.
