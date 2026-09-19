# 04 — Spike removal

**What to build:** remove the throwaway harness now that the real thing
exists. The debug spike screen, its route registration, its Settings debug
entry, the one-shot spike channel methods (test-image scan, colour-mode call,
HDR/SDR ratio sampling), and the throwaway view type/factory go away
entirely. What survives is whatever ticket 01 already absorbed into the real
implementation. Nothing user-visible changes except the debug entry
disappearing from Settings in debug builds. The manifest's `EnableHcpp=false`
stays — that is the recorded decision, not a leftover (see the spec's spike
outcome; do not re-enable HCPP without re-measuring its per-frame log spam).

**Blocked by:** 01 — Native photo view live in the gallery viewer (local
photos); 02 — Zoom and pan in the native matrix. (02 is required so the
removed spike screen does not take the only gesture comparison harness with
it.)

**Status:** done

- [x] No debug-only spike screen, route, Settings entry, or spike channel
      methods remain anywhere in the app or its plugin.
- [x] The spike's scan lesson (no LIMIT token in sort order, exceptions
      surfaced, not swallowed) lives on only in the spec's trap notes — no
      spike scan code ships.
- [x] `EnableHcpp` remains `false` in the manifest.
- [x] `flutter analyze` reports zero issues; the web release build and the
      APK build both succeed.
- [x] The gallery viewer behaves identically before/after this ticket (no
      production code path referenced the removed spike code).
