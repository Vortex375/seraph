# 01 — REMOVE refreshes the global prefix cache

**What to build:** Today, removing a Gallery Source Folder deletes the configuration document and
deliberately does *not* refresh the gallery service's global ingestion prefix cache — so the service
keeps matching (and ingesting) `FileChangedEvent`s for the removed folder's physical prefix until the
next ADD or a restart happens. This is gallery-mode ticket 07's accepted behaviour, and it is also the
reason the reaping feature (ticket 02) cannot compute accurate coverage at REMOVE time.

This ticket reverses that choice: REMOVE calls `refreshPrefixCache` before returning, so the removed
folder's physical prefix drops out of the global prefix set immediately. The tested contract is
intentionally narrowed from "REMOVE touches nothing but the configuration document" to "REMOVE touches
no File Provider and no other service": local Mongo writes (the config-document delete, the prefix-cache
refresh's persisted prefix updates, and — in ticket 02 — the reaper's marks) are permitted, but no NATS
request may leave the gallery service for the File Provider, spaces, or any other service as a result of
REMOVE. `TestRemoveTouchesNoFileProvider` is updated to assert this narrower form.

This is the prerequisite that makes ticket 02's coverage computation correct, and it independently
fixes the stale-prefix-ingestion gap: after REMOVE, events under the removed prefix stop being ingested
without waiting for the next ADD or a restart.

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] REMOVE calls `refreshPrefixCache` (the existing global, cross-all-users refresh) before returning,
      so the removed folder's physical prefix is absent from the cache immediately.
- [ ] No File Provider is contacted and no other service receives a NATS request as a result of REMOVE
      — the narrowed `TestRemoveTouchesNoFileProvider` contract holds (local Mongo writes are permitted;
      outbound NATS requests to other services are not).
- [ ] `TestRemoveTouchesNoFileProvider` is updated to assert "no File Provider / no other service"
      rather than "touches nothing but the config document", and still passes.
- [ ] A `FileChangedEvent` for a path under a just-removed folder is no longer ingested (the prefix no
      longer matches) — covered at the gallery integration-test boundary (NATS + Mongo testcontainers).
- [ ] A `FileChangedEvent` for a path under a folder another user still has configured is still ingested
      (the shared physical prefix remains in the global cache).
- [ ] The prefix-cache refresh failure on REMOVE does not fail the REMOVE itself (best-effort, mirroring
      ADD's existing handling) — the response still succeeds, and a later ADD/spaces.changed will retry.
