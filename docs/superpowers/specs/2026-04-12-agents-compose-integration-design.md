# Agents Compose Integration Design

## Goal

Integrate the refactored `agents` service into the repository root `docker-compose.yml` and `docker-compose.dev.yml` so the full Seraph stack can be brought up end-to-end, with the agents service connected to the same in-stack NATS broker and able to run ingestion against the live development environment.

## Decisions

- Root compose files become the canonical full-stack source of truth for the agents service.
- Root compose service names are renamed from `agentos-db` and `agentos-api` to `agents-db` and `agents-api`.
- `docker-compose.dev.yml` uses a built image for the agents service instead of a bind mount with `uvicorn --reload`.
- The agents service connects to the stack-local NATS instance with `NATS_URL=nats://nats:4222`.
- Stale Agno-era environment variables are removed from the root compose files.

## Scope

### In scope

- Update `docker-compose.yml` and `docker-compose.dev.yml` to reflect the current AgentScope/FastAPI agents runtime.
- Ensure the root compose files expose the env vars required by the current agents service.
- Align `agents/compose.yaml` naming and settings with the root compose naming so the standalone compose file does not drift immediately.
- Verify compose rendering and bring up the dev stack far enough to confirm the agents service can start against stack-local dependencies.

### Out of scope

- Reworking the overall Seraph service topology.
- Changing service-to-service auth design beyond what the current agents runtime already expects.
- Broader Docker cleanup unrelated to the agents integration.

## Current Problem

The root compose files still describe the old Agno/AgentOS shape:

- service names still use the `agentos-*` prefix
- root env vars include obsolete Agno settings
- the root files do not reflect the current FastAPI + AgentScope runtime contract

This leaves two different compose definitions for the same app: the root compose files and `agents/compose.yaml`. The standalone file has the newer runtime wiring, but the full-stack files are what matter for end-to-end development. As a result, `docker-compose.dev.yml` is not yet a reliable way to test the entire stack with agents ingestion enabled against in-stack NATS.

## Proposed Design

### Compose Ownership

The repository root compose files remain the canonical definition for full-stack orchestration.

- `docker-compose.yml` defines the production-like full-stack topology.
- `docker-compose.dev.yml` defines the development full-stack topology.
- `agents/compose.yaml` remains available for isolated agents work, but its service naming and env shape must match the root files closely enough to avoid confusion.

This avoids compose indirection while making the root files the dependable path for end-to-end testing.

### Service Naming

Rename these root services:

- `agentos-db` -> `agents-db`
- `agentos-api` -> `agents-api`

All internal references in the compose files are updated accordingly:

- `depends_on`
- `DB_HOST`
- container names if present in the standalone compose file

This matches the current runtime naming and removes the last visible Agno/AgentOS service identity from the integrated stack.

### Agents Service Runtime Contract

The root compose files should reflect the current runtime in `agents/app/main.py` and related settings.

Required environment contract:

- `RUNTIME_ENV`
- `DB_HOST`
- `DB_PORT`
- `DB_USER`
- `DB_PASS`
- `DB_DATABASE`
- `OPENAI_API_KEY`
- optional `OPENAI_BASE_URL`
- `CHAT_MODEL_NAME`
- `EMBEDDING_MODEL_NAME`
- `EMBEDDING_DIMENSIONS`
- `NATS_URL`
- `KB_INGEST_ENABLED`
- `KB_MAX_FILE_BYTES`
- `KB_PULL_BATCH`
- `KB_FETCH_TIMEOUT`
- `KB_ACK_WAIT_SECONDS`
- `KB_CONSUMER_NAME`
- `KB_INGEST_PARALLELISM`
- `KB_IDLE_BACKOFF_BASE`
- `KB_IDLE_BACKOFF_MAX`
- `SERAPH_AUTH_USER_HEADER`

Obsolete Agno-era env vars are removed from the root compose files because they no longer describe the running service:

- `DATA_DIR`
- `AGNO_DEBUG`
- `WAIT_FOR_DB`
- `PRINT_ENV_ON_LOAD`
- `EXA_API_KEY`

### NATS and End-to-End Ingestion

The agents service runs on the shared `internal` network and connects to the same `nats` service as the rest of Seraph using:

- `NATS_URL=nats://nats:4222`

That ensures:

- spaces retrieval calls resolve against the same stack-local NATS broker
- ingestion consumes the same file-changed events as the rest of the system
- `docker-compose.dev.yml` becomes a real end-to-end environment instead of an isolated partial setup

### Dev Compose Behavior

For `docker-compose.dev.yml`, the agents service uses a built image, not a source bind mount.

Rationale:

- user explicitly wants built-image behavior in dev compose
- dev compose should resemble the integrated stack being tested end-to-end
- this reduces differences between `docker-compose.yml` and `docker-compose.dev.yml`

The dev file still keeps the usual development-friendly knobs such as exposed ports and debug-oriented env values where appropriate.

### Standalone Agents Compose Alignment

`agents/compose.yaml` stays as a convenience for isolated agents work, but it should align with the root naming and runtime contract:

- `agents-db`
- `agents-api`
- current env vars

It should not remain the hidden source of truth for runtime settings that differ from the root stack.

## Verification Plan

### Compose validation

- `docker compose -f docker-compose.yml config`
- `docker compose -f docker-compose.dev.yml config`

These must render successfully after the rename and env cleanup.

### End-to-end stack bring-up

- `docker compose -f docker-compose.dev.yml up -d --build`
- `docker compose -f docker-compose.dev.yml ps`

Expected:

- `agents-db` is healthy or running
- `agents-api` is running
- `nats` is running

### Runtime sanity

Inspect `agents-api` logs and confirm startup reaches dependency initialization without hostname mismatches or stale env usage.

Key success criteria:

- DB hostname resolves to `agents-db`
- NATS hostname resolves to `nats`
- ingestion is able to start against stack-local NATS when enabled

If external model credentials are absent, that may limit deeper runtime checks, but compose wiring and dependency connectivity should still be validated.

## Risks

### Service rename fallout

Renaming root services may affect any undocumented local scripts or habits that still reference `agentos-*`.

Mitigation:

- keep the rename limited to compose definitions
- verify compose config rendering immediately after the change

### Standalone/root drift returning later

If `agents/compose.yaml` is not updated alongside the root files, the repo will quickly regress to two different runtime definitions.

Mitigation:

- update the standalone compose file in the same change set where necessary

### Environment-limited verification

End-to-end runtime checks may still be bounded by local secrets or unavailable external providers.

Mitigation:

- separate compose/network verification from model-provider verification
- report exactly which checks were completed and which were environment-gated
