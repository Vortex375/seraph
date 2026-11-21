# 03 — App: Jobs screen for admins

**What to build:** Per spec "App":

- `JobsService.list()` (`GET /api/jobs`) and a `Job` model parsing the new fields (missing numbers mean
  unknown).
- `JobsView` at `/jobs` ("Background jobs"), registered in `app.dart`; polls every 3 s while visible,
  stops when not; pull-to-refresh.
- Nav entry "Jobs" in `_buildDropdown` under "Spaces Admin", inside `if (isAdmin)`.
- Row: description, status message, progress bar (determinate / indeterminate / none), "N waiting",
  relative update time, "stalled" chip (running and older than 2 min), failed message in error colour.
  Order: running, failed, others; newest first within each.

**Blocked by:** 02

**Status:** done

- [x] The "Jobs" entry is absent for a non-admin and present for an admin.
- [x] A Batch Job with `total > 0` shows a determinate bar at `done / total`; with `total` unknown and
      `running`, an indeterminate bar; `completed` shows no bar.
- [x] A Queue Job with `pending` 1234 shows "1,234 waiting"; `idle` shows no bar.
- [x] A `running` Job last updated 3 minutes ago shows "stalled".
- [x] A 403 shows "Only space admins can see jobs"; a network error shows a retry message.
- [x] Polling stops when leaving the screen (no requests while another screen is shown).
- [x] Gates: `flutter analyze` (zero issues), `flutter test`, `flutter build web --release
      --base-href=/app/`.
