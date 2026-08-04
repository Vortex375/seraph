# 25 — Queue policy, failure buckets and the failure list

**What to build:** Backup behaves sensibly under load and fails visibly rather
than silently.

- **Two priority classes.** Photos observed after setup, or after the last
  completed pass, preempt the historical backlog; newest-first within each
  class. Otherwise a photo taken right after configuring a 9,000-image backup
  lands at position 9,001.
- **Three to four parallel uploads**, tunable. Mobile radios have high latency
  and per-connection throughput limits, so parallelism hides latency more than
  it saturates bandwidth. Beyond about four the app competes with itself for the
  radio and for the gateway's request budget.
- **Three failure buckets, handled differently.**
  - *Transient* — network gone, 5xx, timeout — per-item exponential backoff
    **plus a global backoff**, so a downed server does not produce thousands of
    independent retry storms.
  - *Permanent* — read-only Space, out of space, unreadable local file — stop
    retrying and move to a **visible failure list with a reason**. Never
    silently dropped, never retried forever.
  - *Moved target* — local file changed or vanished mid-upload — re-queue or
    discard, never mark synced.
- **The queue is derived state, not durable truth.** It is rebuildable at any
  time by diffing the device's photos against the Verified set in the local
  mirror, so a lost or corrupted queue costs a scan, not a backup.

**Blocked by:** 22

**Status:** claimed

- [ ] A photo taken during a large backlog run uploads before the remaining backlog
- [ ] Within each priority class, newer photos upload first
- [ ] Uploads run with a tunable parallelism, defaulting within three to four
- [ ] Transient failures retry with increasing per-item delays
- [ ] A server that is down triggers a global backoff rather than per-item retry storms
- [ ] Permanent failures stop retrying and appear in a visible failure list with a comprehensible reason
- [ ] The failure list can be retried by the user, and fixing the underlying cause requires no reconfiguration
- [ ] A photo that changed or vanished mid-upload is re-queued or discarded and never marked synced
- [ ] Deleting the queue entirely leaves the next run rebuilding it from a scan, with nothing re-uploaded that is already Verified
- [ ] Covered at the app's mirror seam, including a deleted-queue rebuild test and a global-backoff test with a permanently failing backend
