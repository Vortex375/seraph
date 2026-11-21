# 06 — Thumbnail warming reports a Job

**What to build:** Per spec "Producers": in the thumbnailer, Queue Job `thumbnailer.warm` from consumer
`SERAPH_THUMBNAILER_WARM` (`thumbnailer/thumbnailer/warm.go`), polled every 10 s; description "Warming
thumbnails". Stop the poller with the consumer.

**Blocked by:** 01

**Status:** ready-for-agent

- [ ] With warm requests queued, `thumbnailer.warm` reports `running` and a `pending` that falls as they
      are processed.
- [ ] Once the queue is empty it reports `idle` / `pending` 0, once (no repeated publishes while idle).
- [ ] Gates: `go test ./...` in `thumbnailer`.
