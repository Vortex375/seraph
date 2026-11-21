# 01 — Job progress contract and shared reporter

**What to build:** Per spec "Job shapes" and "Contract":

- `events/schema.avsc`: add `state` (string, default `""`), `done` (long, default `0`), `total` (long,
  default `-1`), `pending` (long, default `-1`) to `JobEvent`; regenerate `events.go` with `make` in
  `events/`.
- `messaging`: `NewJob(nc, key, description)` with `Progress`, `Pending`, `Complete`, `Fail`; publishes to
  `seraph.jobs.<key>`; 5 s throttle per job with trailing flush, immediate state changes, 30 s heartbeat
  while `running`, publish errors logged and swallowed.
- file-indexer: replace the hand-built `JobEvent` in `updateProgress` with the reporter, as Queue Job
  `file-indexer`.
- `CONTEXT.md`: the **Job** term is already added by this track's spec commit; keep it accurate if the
  contract changes.

**Blocked by:** —

**Status:** ready-for-agent

- [ ] A job's updates arrive on `seraph.jobs.<key>` and land in the `SERAPH_JOBS` KV under `<key>`.
- [x] 100 `Progress` calls within 1 s publish at most one message immediately plus one trailing message
      carrying the last values.
- [x] `Complete`, `Fail` and `Pending(0, …)` publish at once, even inside a throttle window.
- [x] A `running` job with no calls republishes within 30 s; a `completed` one does not.
- [x] A NATS publish error is logged and does not panic or return to the caller.
- [ ] file-indexer reports `state` `running` with `pending` > 0 while indexing and `idle` with `pending` 0
      after.
- [x] Gates: `go test ./...` in `messaging`, `events`, `file-indexer`.

## Comments

**Coordinator review (2026-11-21):** Accepted. Added: unchanged values are not republished (a polled idle
Queue Job publishes `idle` once; running Jobs stay fresh through the heartbeat), with
`TestJobIdleQueuePublishesOnce`. The two unticked criteria (KV landing, file-indexer states) are verified
end to end in the deploy check after 02–07.
