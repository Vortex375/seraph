# Audio player engine: just_audio with token-safe streaming

Status: ready-for-agent

## Problem Statement

Audio playback in the app is unreliable and costly on battery. When a user plays a folder of songs, the
first track or two play fine. Later tracks then often fail with a playback error. The cause is how the
player is fed. Every queue item is handed to the player as a fixed URL plus a fixed `Authorization:
Bearer` header. The OIDC access token is captured when the queue is built and lives for about 5
minutes, so by the time playback reaches item 3 or 4 its token has usually expired. The gateway then
answers 403 and the track fails.

An earlier fix refreshes the token every 30 seconds while music plays and rewrites every queued item's
headers inside the live player (remove, re-add, move per item). That fix is racy and does not reliably
work. The player engine itself (media_kit / libmpv, with the full video native libraries bundled for
audio) mostly decodes in software. Its position stream also triggers a lock-screen state update on every
tick, which drains the battery during long listening sessions.

## Solution

Replace the audio engine with **just_audio** (a Flutter Favorite, by the author of the `audio_service`
package the app already uses for background playback). Keep `audio_service` as the background, lock-screen
and notification layer.

Stop baking credentials into queue items. On Android, each queue item becomes a custom streaming audio
source (just_audio's `StreamAudioSource`). The player asks it for byte ranges as it needs them, and each
request is made at that moment through the app's authenticated HTTP path. That path reads the current
access token and, if the gateway answers 401/403, force-refreshes the token and retries once. A token can
therefore never be "stale in the playlist": nothing is fetched until it is needed, and every fetch uses a
fresh credential.

On web, the gateway authenticates the browser with its session cookie and there is no bearer token. Queue
items there stay plain file URLs, so the expiry problem does not exist on web. (On web, just_audio's
`StreamAudioSource` would download the whole file into a base64 data URL before playing, so it must not
be used there.)

For the user: a folder of songs plays start to finish, seeking works anywhere in any track, lock-screen
and notification controls keep working, and battery use drops. Playback uses Android's own media stack
(ExoPlayer), which decodes in hardware.

## User Stories

1. As a listener, I want to tap a song in a folder and have the whole folder's songs queued, so that playback continues through the album without me tapping each track.
2. As a listener, I want the 5th, 10th or 30th track in a queue to start playing when its turn comes, so that long albums and playlists don't stop with a playback error.
3. As a listener, I want playback to keep working after more than 5 minutes have passed since I started the queue, so that access-token lifetime is invisible to me.
4. As a listener, I want to skip to the next track, so that I can move past songs I don't want to hear.
5. As a listener, I want to go back to the previous track, so that I can replay a song.
6. As a listener, I want to seek anywhere within a track, including far ahead of what has been downloaded, so that I can jump to a part of a long recording.
7. As a listener, I want seeking to keep working when the token that was valid at the start of the track has since expired, so that long tracks (podcasts, DJ sets, audiobooks) remain seekable.
8. As a listener, I want to pause and resume, so that I can interrupt listening.
9. As a listener, I want resume after a long pause to work without a playback error, so that coming back to the app later is not punished by an expired token.
10. As a listener, I want the player to release itself after being paused for a long time (as today, 5 minutes), so that a forgotten paused player does not hold resources.
11. As a listener, I want lock-screen and notification controls (play/pause, next, previous) to keep working, so that I can control playback without unlocking my phone.
12. As a listener, I want the current track title and duration shown in the notification and lock screen, so that I know what is playing.
13. As a listener, I want playback to continue with the screen off and the app in the background, so that I can listen like I would with any music app.
14. As a listener, I want headset / Bluetooth media buttons to keep working, so that I can control playback from my headphones.
15. As a listener, I want the in-app player view to show the current title, position, duration and a working seek slider, so that the existing UI keeps working on the new engine.
16. As a listener, I want the mini player / media bottom bar to show play state and buffering correctly, so that I can tell when audio is loading.
17. As a listener, I want a clear error message when a track genuinely can't be played (missing file, unsupported format, real permission denial), so that I am not left with silent failure.
18. As a listener, I want a single unplayable track to produce an error rather than a hung player, so that I can skip past it.
19. As a listener, I want the close button in the player to stop playback and dismiss the notification, so that I can end a session cleanly.
20. As a listener on a phone, I want listening to music to use noticeably less battery than today, so that I can listen for hours.
21. As a web user, I want to play audio files from the file browser with the same controls, so that the web app is on par with the phone app.
22. As a web user, I want playback to start streaming promptly, without the whole file being downloaded first, so that large files start quickly.
23. As a web user, I want playback to keep working across a long queue, so that I can listen through a folder.
24. As a user who watches videos in the app, I want video playback to keep working exactly as before, so that the audio change doesn't regress video.
25. As a user of a server without authentication (no-auth mode), I want audio to play without any token, so that unauthenticated setups keep working.
26. As a user viewing a share link on web, I want audio in a shared folder to play, so that recipients of shares can listen.
27. As a user browsing files while music plays, I want the file browser to keep working, so that the change in token-refresh triggers doesn't break other features.
28. As a maintainer, I want credentials to flow through one authenticated fetch path instead of being duplicated into every queue item, so that the token-refresh logic lives in one place.
29. As a maintainer, I want the per-item header-rewriting and the 30-second audio token-refresh timer removed, so that there is less fragile code to debug.
30. As a maintainer, I want the authenticated byte-range fetch covered by unit tests (range, refresh-and-retry, real denial), so that a regression in the token path is caught without a device.

## Implementation Decisions

**Engine.** Add `just_audio` (current 0.10.x) to the app. The app's `audio_service` handler (the
`BaseAudioHandler` subclass with queue and seek mixins) is rewritten to drive a just_audio `AudioPlayer`
instead of a media_kit `Player`. `audio_service` stays as is (version, Android service declaration,
foreground-service permissions). media_kit and its video packages stay, used only for video playback.
The audio handler no longer imports media_kit. `just_audio_background` is not used: the app already has
its own `audio_service` handler.

**Queue.** The handler's queue (audio_service `MediaItem`s, id = file URL, title = file basename) maps 1:1
to just_audio's playlist via `setAudioSources(sources, initialIndex:, useLazyPreparation: true)`. Lazy
preparation means an item is only opened when it is about to play. `ConcatenatingAudioSource` is
deprecated in 0.10 and must not be used. The queue item no longer carries headers in `extras`.

**State mapping.** The handler derives `playbackState` from just_audio's single `playbackEventStream`
plus `playingStream`. It maps just_audio's processing states (idle / loading / buffering / ready /
completed) onto audio_service's, and sets `queueIndex` from `currentIndex`. It publishes `updatePosition`
from the playback event, not from a high-frequency position stream; audio_service extrapolates position
between updates. It updates `mediaItem` (including duration from `durationStream`) when the current
index or the duration changes. Controls and compact actions stay as today: play/pause, previous, next.
Player errors surface as audio_service error state with a message, which the existing controller turns
into the "Playback error" snackbar.

**Pause auto-stop.** Keep the current behaviour: after 5 minutes paused, the handler stops and releases
the player.

**Authenticated stream source (Android and every non-web platform).** A new `StreamAudioSource`
subclass is constructed with the file's path or URL and a fetch function. Its `request(start, end)`
issues an HTTP GET for that file with a `Range: bytes=start-(end-1)` header (open-ended when `end` is
null), using the current bearer token. It returns a `StreamAudioResponse` built from the response:
`sourceLength` from `Content-Range` total (or `Content-Length` for a full-body 200), `contentLength`,
`offset` = start, `contentType` from the response, and the body as a stream. On a 401/403 it
force-refreshes the token once and retries once. A second failure propagates as an error, which
just_audio surfaces as a player error. The refresh-and-retry reuses the app's existing reactive token
recovery in the file service (the same 401/403 → `refreshTokenIfNeeded(force: true)` → retry once
pattern the file service's WebDAV calls and file byte fetch already use). It must not grow a second
implementation. The fetch is a streamed response (`ResponseType.stream`), never a full in-memory body.

The fetch function is the seam: production passes the file service's authenticated ranged fetch, tests
pass a fake.

**Server.** No server change. The gateway's WebDAV GET goes through Go's `golang.org/x/net/webdav`,
which serves file content with `http.ServeContent`, so `Range` requests and `206 Partial Content` are
already supported.

**Web.** On web (`kIsWeb`), queue items are plain URI audio sources (`AudioSource.uri`) with no headers.
The browser sends the gateway session cookie, which is how the web build already authenticates (its
login controller runs in no-auth mode against the cookie session). `StreamAudioSource` must not be used
on web, because just_audio's web implementation reads the entire stream into a base64 data URL before
playback.

**No-auth servers.** With no current user, the authenticated fetch sends no `Authorization` header, as
the file service's header helper already does, and the stream source works unchanged.

**Android cleartext.** just_audio serves `StreamAudioSource`s to ExoPlayer through a local HTTP proxy on
`127.0.0.1`, which needs cleartext traffic to localhost. Add an Android network security config that
permits cleartext only for `127.0.0.1` / `localhost`, and reference it from the application manifest.
Do not enable app-wide `usesCleartextTraffic`. Because this touches `android/`, the APK build is a
mandatory gate.

**Deletions.**
- The handler's `setHeaders` custom action and the per-item remove / re-add / move header rewrite.
- The handler's 30-second token-refresh timer and the `refreshToken` custom event.
- The controller's listeners that forwarded headers to the handler on user change and refreshed the
  token on that custom event.
- Headers in `MediaItem.extras`.

Token freshness during playback is now guaranteed by the per-request recovery. Comments elsewhere that
name the "30s audio timer" as a proactive refresh trigger (login controller, upload backend, file
service, token-recovery test) must be updated to drop it.

**Startup.** `MediaKit.ensureInitialized()` stays for video. Nothing new is needed at startup for
just_audio.

**Dependencies.** `media_kit_libs_video` stays for video. Add just_audio at the current 0.10.x. Linux/Windows backends (`just_audio_media_kit`) are out of scope. `audio_service_mpris`
stays untouched.

## Testing Decisions

- **One seam: the authenticated stream source's `request(start, end)`.** Tests construct the source with
  a fake ranged-fetch function and a fake token refresh, and only assert observable behaviour: the range
  requested, the fields of the returned `StreamAudioResponse`, and whether a refresh happened and how
  many fetches were made. Cases:
  - Open-ended request (`start` only, or neither) → correct `Range` header; `sourceLength`,
    `contentLength`, `offset` taken from `Content-Range` on a 206.
  - Bounded request (`start`, `end`) → inclusive-end `Range` header (`end - 1`).
  - Server ignores `Range` and answers 200 with a full body → `sourceLength` = `contentLength` =
    `Content-Length`, offset 0.
  - First fetch 403 (and separately 401), retry succeeds → one refresh, two fetches, the retry's data is
    returned. This is the expired-token case.
  - First fetch 403, retry 403 → error propagates. This is a real permission denial.
  - Non-auth failure (404, 500, network error) → no refresh, error propagates.
- **The audio_service handler is not unit-tested.** It is thin wiring around just_audio and is verified
  on a device (ticket 02) and by the build gates.
- **Prior art:** the token-recovery unit tests under the gallery mirror tests build `DioException`s with a
  status and count `op`/`refresh` calls without a real transport. Follow that style. The fake fetch for
  the stream source can be a closure, not a Dio adapter.
- **Gates (per AGENTS.md):** `flutter analyze` with zero issues, `flutter test`,
  `flutter build web --release --base-href=/app/`, and `flutter build apk` (mandatory because the
  network security config touches `android/`).

## Out of Scope

- Linux, Windows, macOS and iOS audio (no `just_audio_media_kit`; desktop apps may come later).
- Video playback engine changes. media_kit stays for video.
- Server-side changes: signed or long-lived media URLs, Subsonic endpoints, Range handling (already works).
- Offline caching of tracks (`LockCachingAudioSource` or similar), gapless playback, shuffle and repeat
  modes, playlist persistence across app restarts, and new player UI. Those are follow-on audio player
  features.
- Changing the login and token-refresh machinery itself. It is only called, not changed.

## Further Notes

- Survey basis (pub.dev, Nov 2026): just_audio 0.10.6 is the only Flutter Favorite audio player.
  audioplayers has no playlist or background story. media_kit 1.2.6 had its last release 10 months ago.
- Why per-request auth rather than refreshing headers: just_audio's headers are fixed per source too,
  and swapping sources mid-playlist is what made the media_kit approach fragile. Fetching through a
  `StreamAudioSource` moves auth to the moment of each byte-range request, which is the only point
  where a fresh token is guaranteed.
- Behaviour to watch on device: ExoPlayer issues a new range request on every seek and on buffer
  refill. With the access token lifetime at 5 minutes, a long track exercises the 403 → refresh → retry
  path mid-track. That is the core scenario for ticket 02.
