# 18 — Sync Pair configuration

**What to build:** An Android user maps a folder on their phone to a folder in
Seraph. Everything under the phone folder will be uploaded there, relative path
preserved. More than one Sync Pair can be configured, so the camera folder and
the screenshots folder can go to different places.

A Sync Pair's Seraph folder **automatically becomes a Gallery Source Folder**, so
the user does not configure the same folder twice. Gallery Source Folders remain
independently configurable, so folders nothing uploads to still appear in the
gallery.

**Sync Pairs live in the app's local database**, not on the server: they
reference a Local Source that exists on exactly one device. Losing them to a
data wipe costs a reconfiguration, not data.

**A Local Source may appear in at most one Sync Pair.** Otherwise a photo has two
remote paths and two verification states, and the remote path stops being a pure
function.

No uploading in this ticket — configuration only.

**Blocked by:** 06, 15

**Status:** ready-for-agent

- [ ] A user can create a Sync Pair by picking a device folder and a Seraph folder, using the pickers already in the app
- [ ] Creating a Sync Pair adds its Seraph folder to the user's Gallery Source Folders
- [ ] Multiple Sync Pairs can be configured, targeting different Seraph folders
- [ ] Adding a device folder already covered by another Sync Pair is refused with a clear explanation
- [ ] The pairs list shows what each pair maps to and how many photos it covers
- [ ] Sync Pairs persist across app restarts
- [ ] Sync Pair configuration is expressed against a Local Source, not a hardcoded path, and the UI works entirely above that seam
- [ ] Configuration is unavailable on platforms without a Local Source implementation, rather than present and broken
- [ ] Covered at the app's mirror seam with a fake Local Source and a stubbed backend
