# 22 — Headless sync engine and foreground data-sync service

**What to build:** A user starts a backup run and it keeps going with the screen
off, showing progress in a notification. They can pause and resume it, and see
how many photos remain and roughly how much data.

The sync engine moves into a **headless Dart isolate**, driven here by a
foreground data-sync service for user-initiated batches. The manifest currently
declares only the media-playback foreground service type and needs the data-sync
type added.

**The engine is headless by construction**: no GetX controllers, no build
context, no UI dependencies. **The local database is the interface between the
engine and the UI** — the engine writes state, the UI observes and renders. This
is a deliberate departure from the rest of the app, where controllers hold
reactive state, and it is what makes the engine runnable with no UI attached at
all.

A native engine was rejected: it would duplicate the state machine, database
access and auth handling outside Dart.

Unattended background scheduling comes later and depends on the cross-isolate
token lock landing first.

**Blocked by:** 20

**Status:** ready-for-agent

- [ ] A user-initiated backup run continues with the app backgrounded and the screen off
- [ ] Progress — photos remaining and approximate data volume — is visible in a notification and in the app
- [ ] The run can be paused and resumed, and pausing takes effect promptly
- [ ] The engine contains no UI dependencies and can run with no UI attached
- [ ] The UI reflects engine state by observing the local database, not by being called by the engine
- [ ] Killing and restarting the app mid-run leaves no item in a stuck intermediate state
- [ ] The engine and the UI can both touch the database without corrupting it
- [ ] The manifest declares the data-sync foreground service type
- [ ] Covered at the app's mirror seam by running the engine headlessly against a stubbed backend and a fake Local Source, asserting on resulting mirror state
