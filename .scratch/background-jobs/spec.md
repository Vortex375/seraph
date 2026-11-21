# Background jobs: progress reporting and an admin Jobs screen

Status: resolved

Phase: specification. Drafted on 2026-11-21. Tickets in `issues/`.

Vocabulary: [CONTEXT.md](../../CONTEXT.md)

## Problem Statement

Seraph does a lot of slow work in the background: indexing Gallery Source
Folders, warming Thumbnails, extracting photo metadata and, with
[gallery-ai](../gallery-ai-classification/spec.md), classifying every photo. An
admin cannot see any of it. After deploying gallery-ai to a library of tens of
thousands of photos, there is no way to tell whether classification is
running, how far it got, or whether it stalled.

The pieces for this already exist but are barely used:

- `JobEvent` (Avro, `events/schema.avsc`): `key`, `description`,
  `statusMessage`, `properties`.
- The `jobs` service consumes `seraph.jobs.>` (stream `SERAPH_JOBS`, one
  message per subject) into the `SERAPH_JOBS` KV bucket (14-day TTL).
- `GET /api/jobs` in the gateway lists the bucket with each entry's update time.
- Only one producer: file-indexer reports
  `"Index progress: N remaining"` under key `SERAPH_FILE_INDEXER`.

Nothing reads `/api/jobs` today, and it has no access check.

## Solution

1. **A progress contract.** Extend `JobEvent` with typed progress fields
   (`state`, `done`, `total`, `pending`), and add a small shared reporter that
   every producer uses. The reporter throttles updates, sends a heartbeat
   while a job runs and always sends state changes.
2. **Every background process reports.** Gallery indexing, metadata
   extraction, Thumbnail warming and AI classification each publish one or
   more Jobs. File-indexer moves onto the same contract.
3. **Admin-only API.** `GET /api/jobs` answers only space admins and returns
   the new fields.
4. **A Jobs screen in the app.** Shown in the main navigation dropdown, below
   "Spaces Admin" and only for space admins. It lists every Job with its
   progress and refreshes itself while open.

## User Stories

1. As an admin, I open "Jobs" from the main navigation and see every
   background process Seraph is running or has recently finished.
2. As an admin, I see how many photos AI classification has left to analyse,
   and the number goes down while I watch.
3. As an admin, after adding a Gallery Source Folder, I see its indexing Job
   count up the photos it has added, then complete.
4. As an admin, I see how many Thumbnails are still waiting to be warmed.
5. As an admin, I see metadata extraction progress for a folder being rescanned.
6. As an admin, I can tell a Job that stopped reporting (its service crashed)
   from one that is merely slow: it is marked stalled.
7. As an admin, I see a failed Job with its error message.
8. As a non-admin user, I do not see the Jobs entry, and the API refuses me.

## Implementation Decisions

### Job shapes

A **Job** is one background process, identified by its `key`. Every Job has one
of two shapes:

- **Queue Job**: an open-ended JetStream consumer, such as the gallery ingest
  queue or the gallery-ai analysis queue. It reports its backlog: `pending` is
  the consumer's `NumPending + NumAckPending`. Its `state` is `running` while
  the backlog is above 0 and `idle` once it is empty.
- **Batch Job**: a finite pass, such as a folder backfill or a re-tag pass. It
  reports `done` and, when known, `total`. Its `state` moves
  `running` → `completed`, or `running` → `failed` with the error in
  `statusMessage`.

### Contract (ticket 01)

Add these fields to the `JobEvent` record in `events/schema.avsc`, then
regenerate with `make` in `events/`:

| field     | type   | default | meaning                                              |
| --------- | ------ | ------- | ---------------------------------------------------- |
| `state`   | string | `""`    | `running` \| `idle` \| `completed` \| `failed`       |
| `done`    | long   | `0`     | units finished in this Batch Job                     |
| `total`   | long   | `-1`    | Batch Job size; `-1` means unknown (indeterminate)   |
| `pending` | long   | `-1`    | Queue Job backlog; `-1` means not a Queue Job        |

`description` stays the human title, for example "AI classification" or
"Indexing /Photos/2024". `statusMessage` stays a one-line human summary, and
on a failed Job it carries the error. `properties` stays free-form; nothing in
this track relies on it.

**Old KV entries.** `JobEvent` is binary Avro without the writer schema, so
entries written with the old schema do not decode with the new one. The
gateway skips and logs undecodable entries instead of failing the whole list.
File-indexer's entry is overwritten on its next update, and anything else
expires through the bucket TTL.

**Reporter.** Add a reporter in the shared `messaging` module (it already
depends on NATS; it gains a dependency on `events`). Every producer uses it;
none builds `JobEvent` by hand.

- `messaging.NewJob(nc, key, description)` returns a job with these methods:
  - `Progress(done, total, msg)` (Batch Job)
  - `Pending(n, msg)` (Queue Job; `n == 0` means `idle`)
  - `Complete(msg)`
  - `Fail(err)`
- **Publishing.** Publishes to `seraph.jobs.<key>` (`events.JobsTopicPattern`).
  Keys are dot-separated lowercase, for example `gallery.backfill.<folderId>`.
  They are valid both as NATS subject tokens and as KV keys.
- **Throttling.**
  - At most one publish per 5 s per job.
  - A change of `state` is always published at once.
  - The last value before a throttled gap is never lost: it is flushed when
    the gap ends.
- **Heartbeat.** A job in state `running` republishes at least every 30 s,
  even when nothing changed. That is what lets the app detect stalled Jobs.
- **Queue Jobs.** The owning service polls its consumer's info every 10 s and
  calls `Pending`. This follows the existing pattern in file-indexer's
  `updateProgress`.
- **Failure.** A publish error is logged and never fails the work being
  reported.

**File-indexer.** It moves to the reporter as a Queue Job under the new key
`file-indexer`. The old `SERAPH_FILE_INDEXER` entry expires through the TTL.

### Jobs API (ticket 02)

- `GET /api/jobs`:
  - Returns 403 unless `auth.IsSpaceAdmin`. That is the same check as
    `services.go` and `spaces.go`; no-auth mode counts as admin.
  - Each entry has the `JobEvent` fields plus `time`, which is already the KV
    entry's update time.
  - Undecodable entries are skipped and logged (see "Old KV entries").
- The `jobs` service itself is unchanged: it already copies the stream into KV.

### Producers

| key                             | shape | owner        | source                                                                  |
| ------------------------------- | ----- | ------------ | ----------------------------------------------------------------------- |
| `file-indexer`                  | queue | file-indexer | existing `updateProgress`                                               |
| `gallery.ingest`                | queue | gallery      | consumer `SERAPH_GALLERY_INGEST`                                        |
| `gallery.backfill.<folderId>`   | batch | gallery      | `runBackfill`: `done` = entries upserted, `total` unknown (the file index list API has no count) |
| `gallery.rescan.<folderId>`     | batch | gallery      | `runRescan`; `statusMessage` names the phase (walking, tombstoning)     |
| `gallery.metadata.<folderId>`   | batch | gallery      | `healPendingMetadata`: `total` = count of pending photos under the prefix |
| `gallery.replay`                | batch | gallery      | `photo_replay.go`: `total` = photo count, `done` = published            |
| `thumbnailer.warm`              | queue | thumbnailer  | consumer `SERAPH_THUMBNAILER_WARM`                                      |
| `gallery-ai.analysis`           | queue | gallery-ai   | consumer `SERAPH_GALLERY_AI`; `statusMessage` also gives the analysed count |
| `gallery-ai.tagging`            | batch | gallery-ai   | the re-tag pass in `tags.go`                                            |
| `gallery-ai.clustering`         | batch | gallery-ai   | the timed full clustering pass in `people.go`                           |

- **Batch descriptions** name the folder by its Space-facing path when one
  resolves, and by its physical prefix otherwise. The screen is admin-only,
  so physical paths are acceptable there.
- **Re-running a Batch Job** under the same key replaces its entry. That is
  intended: the screen shows the latest run.

### App (ticket 03)

- **Screen.** New `JobsView` at route `/jobs`, titled "Background jobs".
- **Navigation.** Navigation entry "Jobs" in `_buildDropdown`, directly under
  "Spaces Admin", inside the same `if (isAdmin)`.
- **Data.** `JobsService.list()` is `GET /api/jobs` with the app's
  authenticated Dio. Polled every 3 s while the screen is visible, stopped
  when it is not, with pull-to-refresh.
- **Each row:**
  - `description` and `statusMessage`.
  - A progress bar:
    - determinate when `total > 0`;
    - indeterminate when `running` and `total` unknown;
    - none otherwise.
  - "N waiting" for a Queue Job with `pending > 0`.
  - "updated 12 s ago" from `time`.
  - Failed Jobs show their message in the error colour.
- **Stalled.** A Job in state `running` whose `time` is more than 2 minutes
  old (four missed heartbeats) shows a "stalled" chip.
- **Order:** `running` first, then `failed`, then everything else, newest
  `time` first within each group.
- **Errors.** A 403 shows "Only space admins can see jobs"; any other error
  shows a retry message. Never a blank screen.
- **Web.** Works on web the same way; there is no platform-specific code.

## Out of Scope

- Cancelling, pausing or retrying Jobs from the app.
- Live push (SSE or WebSocket). Polling is enough for an admin screen; add a
  push channel if the screen ever needs to be instant.
- Jobs scoped to the user (showing a regular user their own folder indexing).
- The Angular web app.
- The `audio-metadata` service. "Metadata extraction" here means gallery photo
  metadata. Adding audio-metadata as another Queue Job is a small follow-up
  if wanted.
- Job history beyond the latest run per key, and beyond the 14-day KV TTL.
- Notifications when a Job finishes or fails.

## Testing Decisions

- **Reporter** (`messaging`): unit tests against an embedded NATS server
  covering:
  - throttling, including that the last value is flushed after a gap;
  - immediate state changes;
  - the 30 s heartbeat (with an injectable clock or a short interval);
  - that a publish error does not propagate.
- **Gateway:**
  - a non-admin gets 403 from `GET /api/jobs`, and an admin gets entries with
    `state`, `done`, `total`, `pending` and `time`;
  - an entry with old-schema bytes is skipped, not a 500.
- **Producers:** each producer ticket adds an integration test (existing
  embedded NATS / testcontainers setup) that runs the process and asserts the
  KV entry at that key reaches the expected final state. For example:
  - a backfill of a fixture folder ends `completed` with `done` equal to the
    fixture count;
  - an empty queue reports `idle`.

  Remember that the gallery integration tests skip silently without
  `DOCKER_HOST`; check the `-v` output for `SKIP`.
- **App:** widget tests:
  - the nav entry is hidden for non-admins and shown for admins;
  - row rendering for each shape (determinate, indeterminate, waiting,
    failed, stalled);
  - the 403 message.

  Gates: `flutter analyze` with zero issues, `flutter test`, and
  `flutter build web --release --base-href=/app/`.

## Further Notes

- **Recommended order:**
  1. Ticket 01 (contract).
  2. Tickets 02 and 03 (screen), so the producers become visible as they land.
  3. Then the producers 04–07, in any order or in parallel. They touch
     different services.
- **For the gallery-ai rollout,** ticket 07 is the one that matters. Together
  with 01–03 it is the minimum to watch classification progress.
- **The analysis Queue Job's backlog** right after the deploy is the
  one-time photo replay (gallery ticket 02 of the AI track). Expect it to
  start at roughly the library size and drain at the ML container's
  throughput.
