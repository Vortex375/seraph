# 01: Audio playback on just_audio with token-safe streaming

**What to build:** A user taps a song in a folder. The folder's songs play start to finish through a
long queue, including tracks reached long after the 5-minute access token has expired. Seeking works
anywhere, and lock-screen and notification controls keep working. On Android, the app's `audio_service`
handler drives a just_audio `AudioPlayer`. Each queue item is an authenticated `StreamAudioSource` that
fetches byte ranges on demand with the current bearer token and recovers from 401/403 by
force-refreshing once and retrying once. On web, items are plain file URLs authenticated by the gateway
session cookie. The old credential plumbing (headers in queue items, the `setHeaders` per-item rewrite,
the 30-second audio token-refresh timer) is deleted. media_kit stays for video only.

See the spec (`../spec.md`) for every decision: queue mapping, state mapping, the stream source
contract, the web branch, the localhost-only cleartext config, and the deletion list.

**Blocked by:** None (can start immediately)

**Status:** done (pending on-device verification in 02)

- [x] `just_audio` 0.10.x is a dependency. The audio handler no longer imports media_kit. Video playback still uses media_kit and is unchanged.
- [x] The handler loads the queue with `setAudioSources(..., initialIndex:, useLazyPreparation: true)`, not `ConcatenatingAudioSource`. Skip next, skip previous, skip to item, seek, play, pause and stop all work through the existing `AudioPlayerController` API.
- [x] `playbackState` (playing, processing state incl. buffering and error, `queueIndex`, `updatePosition`) and `mediaItem` (incl. duration) are derived from just_audio's playback event, playing, current-index and duration streams. Position is published per playback event, not per position tick.
- [x] The existing 5-minute pause auto-stop is preserved.
- [x] On non-web platforms each queue item is a `StreamAudioSource` subclass. Its `request(start, end)` makes a streamed, ranged GET through the file service's existing authenticated path, with a single force-refresh-and-retry on 401/403 that reuses the existing recovery and adds no second implementation. It returns `sourceLength`, `contentLength`, `offset` and `contentType` from the response headers (206 via `Content-Range`; 200 via `Content-Length`).
- [x] On web each queue item is `AudioSource.uri` with no headers. `StreamAudioSource` is never used on web.
- [x] With no logged-in user (no-auth server, web share mode) playback works without an `Authorization` header.
- [x] Android has a network security config that permits cleartext only to `127.0.0.1`/`localhost`, referenced from the manifest. App-wide `usesCleartextTraffic` is not enabled.
- [x] Deleted: `MediaItem.extras` headers; the `setHeaders` custom action and its per-item remove / re-add / move; the 30-second refresh timer and the `refreshToken` custom event; the controller's two listeners that fed them. Comments elsewhere that list the "30s audio timer" as a refresh trigger are updated.
- [x] Unit tests cover the stream source's `request` through a fake fetch and a fake refresh: open-ended range; bounded range with inclusive `end - 1`; 200 full-body fallback; 403→refresh→success; 401→refresh→success; 403→refresh→403 propagates; 404/500 propagate with no refresh.
- [x] Gates pass: `flutter analyze` reports zero issues; `flutter test`; `flutter build web --release --base-href=/app/`; `flutter build apk` (mandatory, since `android/` is touched).

## Comments

**Implementation notes (2026-11-06):**
- `just_audio` 0.10.x has no `useLazyPreparation` parameter on `setAudioSources`. It is an `AudioPlayer` constructor option, and it defaults to `true`.
- The file service's private refresh-and-retry was pulled out into the top-level `retryOnTokenFailure`. The file service and the new audio source both use it, so there is still only one implementation.
- The handler publishes position only on playback events, so the in-app slider would no longer advance on its own. The controller now ticks its `position` from `AudioService.createPositionStream` at 1 s. That runs in Dart only and sends nothing to the native notification.
- Gates: `flutter analyze` reported no issues, `flutter test` passed (399), `flutter build web --release --base-href=/app/` succeeded, and `flutter build apk` succeeded.
