# 17 — Incremental scan and content-observer trigger

**What to build:** A photo taken right now appears in the gallery within
seconds, rather than at the next full scan.

Two mechanisms on top of the full scan, with strictly non-overlapping roles: a
**generation-based incremental scan** as the fast path, available
unconditionally at the app's minimum SDK level; and a **content observer** as a
*trigger only*, not a source of truth.

**The governing rule: no photo's backup status may ever depend on having
received a notification.** A missed notification must degrade latency, never
correctness — which is exactly what the full scan from the previous ticket
guarantees, and why it stays.

**Blocked by:** 15

**Status:** ready-for-agent

- [ ] Taking a photo makes it appear in the gallery within seconds while the app is running
- [ ] The incremental scan processes only photos changed since the last watermark, not the whole library
- [ ] The watermark survives an app restart
- [ ] A photo added while the app was not running is picked up by the next full scan
- [ ] Suppressing every content-observer notification leaves the gallery eventually correct, with latency the only casualty — verified explicitly
- [ ] A burst of changes does not trigger a storm of scans
- [ ] The observer is registered and released with the app's lifecycle and does not leak
- [ ] Covered at the app's mirror seam by driving the fake Local Source, including a test that delivers no notifications at all and asserts eventual correctness
