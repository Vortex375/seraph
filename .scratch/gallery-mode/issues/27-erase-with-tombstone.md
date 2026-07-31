# 27 — Erase with erase tombstone

**What to build:** A photo the user genuinely wants gone can be made gone —
removed from Seraph and from the device in one deliberate action, behind a clear
warning.

**Erase deletes the remote copy first, then trashes the local copy.** For
sensitive photos the urgent half is getting the file off the server, and local
trash still lets the user undo the local loss. Remote deletion is unrecoverable
— Seraph has no trash — so the warning is the only safety net on that side and
must say so plainly.

**This ordering requires an erase tombstone** in the local database, keyed on
local identity `(relative path, display name, size, date taken)`. Without it the
erase silently reverses itself in two ways: the user cancels the trash dialog,
so the local copy is still visible and gets re-uploaded on the next scan; or the
user restores from trash within thirty days, same result. (While an item sits
*in* the trash it is excluded from media-store queries, so the scan will not see
it.)

This tombstone is much narrower than general remote-deletion tombstones, which
stay deferred: *we* performed the erase and know exactly what we erased.

**Erase means erase.** A locally restored photo lives on the device only; the app
offers an explicit "back this up again" rather than re-uploading automatically,
which would contradict an action confirmed through two dialogs.

**Blocked by:** 26

**Status:** ready-for-agent

- [ ] Erase is offered as an explicit action, distinct from every other delete in the app
- [ ] The warning states plainly that the Seraph copy cannot be recovered
- [ ] Erase removes the Seraph copy first, then trashes the device copy
- [ ] Cancelling the device-deletion dialog leaves the photo on the device and it is **not** re-uploaded on any subsequent scan
- [ ] Restoring the photo from the system trash leaves it Device only and it is **not** re-uploaded
- [ ] An explicit "back this up again" action exists and clears the tombstone
- [ ] A batch of photos can be erased in one action with a single system dialog
- [ ] Erase tombstones survive an app restart
- [ ] Failure to delete remotely aborts the erase before anything local is touched
- [ ] Covered at the app's mirror seam, with explicit tests for the cancelled-dialog and restored-from-trash cases running a full scan afterwards and asserting no re-upload
