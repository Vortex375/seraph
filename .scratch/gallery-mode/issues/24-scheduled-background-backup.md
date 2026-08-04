# 24 — Scheduled background backup with user constraints

**What to build:** **Phase 3 ships here.** Photos back themselves up without the
user thinking about it. A photo taken now starts backing up within seconds; the
historical backlog catches up unattended overnight; and none of it costs mobile
data or a dead battery unless the user said it could.

Scheduled background work is the backbone, not a long-lived foreground service:
Android 15 caps cumulative data-sync foreground runtime at roughly six hours a
day. Periodic work handles unattended catch-up; expedited work fires when the
content observer reports a new photo.

**Constraints are declared to the OS and enforced by it**, not polled by us —
unmetered network, charging, battery-not-low — with the user choosing which
apply.

**Blocked by:** 17, 23

**Status:** claimed

- [ ] Photos back up with the app closed, without the user starting anything
- [ ] A newly taken photo triggers an expedited run and starts uploading within seconds
- [ ] The user can require unmetered network, charging, and a battery threshold, and those choices are honoured
- [ ] With constraints unmet, no upload runs and no battery is spent polling
- [ ] Changing constraints takes effect without reconfiguring the Sync Pair
- [ ] The time of the last successful pass is visible in the app, so silence is distinguishable from success
- [ ] A device rebooted mid-backlog resumes without user intervention
- [ ] Background and foreground runs do not both process the same photo
- [ ] Cumulative foreground runtime stays well inside the platform's daily budget
- [ ] Covered at the app's mirror seam by invoking the engine the way the scheduler does and asserting on resulting state; scheduling registration itself is verified by inspection of what is scheduled, not by waiting on the OS
