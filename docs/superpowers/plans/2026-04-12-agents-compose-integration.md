# Agents Compose Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate the refactored agents service into the root compose files so `docker-compose.dev.yml` can run the Seraph stack end-to-end with agents connected to in-stack NATS and ingestion enabled.

**Architecture:** The root compose files become the canonical full-stack definitions for the agents service. They are updated from the old `agentos-*`/Agno shape to the current `agents-*`/FastAPI+AgentScope runtime contract, while `agents/compose.yaml` is aligned so standalone and root orchestration do not drift.

**Tech Stack:** Docker Compose, FastAPI, AgentScope, Postgres/pgvector, NATS JetStream, Seraph microservices

---

### Task 1: Rename and Rewire Root Compose Services

**Files:**
- Modify: `docker-compose.yml`
- Modify: `docker-compose.dev.yml`

- [ ] **Step 1: Write the failing compose-render check assumption**

Treat the current root compose files as failing the desired contract because they still expose `agentos-db` and `agentos-api` plus stale Agno env vars. The verification target for this task is that both root files render successfully after the rename and contain `agents-db` / `agents-api` wiring.

- [ ] **Step 2: Run compose config to establish the baseline**

Run:

```bash
docker compose -f docker-compose.yml config
docker compose -f docker-compose.dev.yml config
```

Expected: both commands may still render, but the files still contain the old `agentos-*` service names and stale runtime env contract.

- [ ] **Step 3: Update `docker-compose.yml` to the current agents runtime contract**

Apply these edits in `docker-compose.yml`:

```yaml
volumes:
  nats-data:
  mongo-data:
  agents-pgdata:
  agents-data:

services:
  agents-db:
    image: agnohq/pgvector:18
    restart: always
    networks:
      - internal
    volumes:
      - agents-pgdata:/var/lib/postgresql
    environment:
      POSTGRES_USER: ${DB_USER:-ai}
      POSTGRES_PASSWORD: ${DB_PASS:-ai}
      POSTGRES_DB: ${DB_DATABASE:-ai}

  agents-api:
    image: seraph-agents
    build:
      context: ./agents
      dockerfile: Dockerfile
    restart: always
    command: uvicorn app.main:app --host 0.0.0.0 --port 8000
    depends_on:
      - agents-db
      - nats
    networks:
      - internal
    ports:
      - 8000:8000
    volumes:
      - agents-data:/data
    environment:
      RUNTIME_ENV: prd
      DB_HOST: agents-db
      DB_PORT: 5432
      DB_USER: ${DB_USER:-ai}
      DB_PASS: ${DB_PASS:-ai}
      DB_DATABASE: ${DB_DATABASE:-ai}
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL:-}
      CHAT_MODEL_NAME: ${CHAT_MODEL_NAME:-gpt-5.2}
      EMBEDDING_MODEL_NAME: ${EMBEDDING_MODEL_NAME:-text-embedding-3-small}
      EMBEDDING_DIMENSIONS: ${EMBEDDING_DIMENSIONS:-1536}
      NATS_URL: nats://nats:4222
      KB_INGEST_ENABLED: ${KB_INGEST_ENABLED:-true}
      KB_MAX_FILE_BYTES: ${KB_MAX_FILE_BYTES:-20971520}
      KB_PULL_BATCH: ${KB_PULL_BATCH:-20}
      KB_FETCH_TIMEOUT: ${KB_FETCH_TIMEOUT:-10.0}
      KB_ACK_WAIT_SECONDS: ${KB_ACK_WAIT_SECONDS:-30}
      KB_CONSUMER_NAME: ${KB_CONSUMER_NAME:-seraph-agents-kb}
      KB_INGEST_PARALLELISM: ${KB_INGEST_PARALLELISM:-4}
      KB_IDLE_BACKOFF_BASE: ${KB_IDLE_BACKOFF_BASE:-0.5}
      KB_IDLE_BACKOFF_MAX: ${KB_IDLE_BACKOFF_MAX:-5.0}
      SERAPH_AUTH_USER_HEADER: ${SERAPH_AUTH_USER_HEADER:-X-Seraph-User}
```

Do not leave these stale variables behind in the root file:

```yaml
DATA_DIR:
AGNO_DEBUG:
WAIT_FOR_DB:
PRINT_ENV_ON_LOAD:
EXA_API_KEY:
```

- [ ] **Step 4: Update `docker-compose.dev.yml` to the current agents runtime contract**

Apply these edits in `docker-compose.dev.yml`:

```yaml
volumes:
  nats-data:
  mongo-data:
  thumbs:
  agents-pgdata:
  agents-data:

services:
  agents-db:
    image: agnohq/pgvector:18
    restart: always
    networks:
      - internal
    ports:
      - 5432:5432
    volumes:
      - agents-pgdata:/var/lib/postgresql
    environment:
      POSTGRES_USER: ${DB_USER:-ai}
      POSTGRES_PASSWORD: ${DB_PASS:-ai}
      POSTGRES_DB: ${DB_DATABASE:-ai}

  agents-api:
    image: seraph-agents
    build:
      context: ./agents
      dockerfile: Dockerfile
    restart: always
    command: uvicorn app.main:app --host 0.0.0.0 --port 8000
    depends_on:
      - agents-db
      - nats
    networks:
      - internal
    ports:
      - 8000:8000
    volumes:
      - agents-data:/data
    environment:
      RUNTIME_ENV: dev
      DB_HOST: agents-db
      DB_PORT: 5432
      DB_USER: ${DB_USER:-ai}
      DB_PASS: ${DB_PASS:-ai}
      DB_DATABASE: ${DB_DATABASE:-ai}
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL:-}
      CHAT_MODEL_NAME: ${CHAT_MODEL_NAME:-gpt-5.2}
      EMBEDDING_MODEL_NAME: ${EMBEDDING_MODEL_NAME:-text-embedding-3-small}
      EMBEDDING_DIMENSIONS: ${EMBEDDING_DIMENSIONS:-1536}
      NATS_URL: nats://nats:4222
      KB_INGEST_ENABLED: ${KB_INGEST_ENABLED:-true}
      KB_MAX_FILE_BYTES: ${KB_MAX_FILE_BYTES:-20971520}
      KB_PULL_BATCH: ${KB_PULL_BATCH:-20}
      KB_FETCH_TIMEOUT: ${KB_FETCH_TIMEOUT:-10.0}
      KB_ACK_WAIT_SECONDS: ${KB_ACK_WAIT_SECONDS:-30}
      KB_CONSUMER_NAME: ${KB_CONSUMER_NAME:-seraph-agents-kb}
      KB_INGEST_PARALLELISM: ${KB_INGEST_PARALLELISM:-4}
      KB_IDLE_BACKOFF_BASE: ${KB_IDLE_BACKOFF_BASE:-0.5}
      KB_IDLE_BACKOFF_MAX: ${KB_IDLE_BACKOFF_MAX:-5.0}
      SERAPH_AUTH_USER_HEADER: ${SERAPH_AUTH_USER_HEADER:-X-Seraph-User}
```

Keep it as a built-image service. Do not restore the old bind mount or `--reload` behavior.

- [ ] **Step 5: Run compose config to verify the rename and env cleanup**

Run:

```bash
docker compose -f docker-compose.yml config
docker compose -f docker-compose.dev.yml config
```

Expected: both commands succeed and render `agents-db` and `agents-api` without Agno-era env vars.

### Task 2: Align Standalone Agents Compose

**Files:**
- Modify: `agents/compose.yaml`

- [ ] **Step 1: Verify the standalone compose drift**

Compare `agents/compose.yaml` against the root compose files after Task 1. The file should still be checked for drift in names, command shape, and env set.

- [ ] **Step 2: Update `agents/compose.yaml` to align with the root runtime contract**

Keep the standalone service names as:

```yaml
services:
  agents-db:
  agents-api:
```

Update the agents API section to align with the root compose contract:

```yaml
  agents-api:
    image: ${IMAGE_NAME:-seraph-agents}:${IMAGE_TAG:-latest}
    command: uvicorn app.main:app --host 0.0.0.0 --port 8000
    environment:
      RUNTIME_ENV: dev
      DB_HOST: agents-db
      DB_PORT: 5432
      DB_USER: ${DB_USER:-ai}
      DB_PASS: ${DB_PASS:-ai}
      DB_DATABASE: ${DB_DATABASE:-ai}
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      OPENAI_BASE_URL: ${OPENAI_BASE_URL:-}
      CHAT_MODEL_NAME: ${CHAT_MODEL_NAME:-gpt-5.2}
      EMBEDDING_MODEL_NAME: ${EMBEDDING_MODEL_NAME:-text-embedding-3-small}
      EMBEDDING_DIMENSIONS: ${EMBEDDING_DIMENSIONS:-1536}
      NATS_URL: ${NATS_URL:-nats://host.docker.internal:4222}
      KB_INGEST_ENABLED: ${KB_INGEST_ENABLED:-true}
      KB_MAX_FILE_BYTES: ${KB_MAX_FILE_BYTES:-20971520}
      KB_PULL_BATCH: ${KB_PULL_BATCH:-20}
      KB_FETCH_TIMEOUT: ${KB_FETCH_TIMEOUT:-10.0}
      KB_ACK_WAIT_SECONDS: ${KB_ACK_WAIT_SECONDS:-30}
      KB_CONSUMER_NAME: ${KB_CONSUMER_NAME:-seraph-agents-kb}
      KB_INGEST_PARALLELISM: ${KB_INGEST_PARALLELISM:-4}
      KB_IDLE_BACKOFF_BASE: ${KB_IDLE_BACKOFF_BASE:-0.5}
      KB_IDLE_BACKOFF_MAX: ${KB_IDLE_BACKOFF_MAX:-5.0}
      SERAPH_AUTH_USER_HEADER: ${SERAPH_AUTH_USER_HEADER:-X-Seraph-User}
```

Remove `--reload` here as well so the standalone file no longer encodes a materially different runtime command.

- [ ] **Step 3: Run standalone compose config to verify it still renders**

Run:

```bash
docker compose -f agents/compose.yaml config
```

Expected: config renders successfully with the same service names and current env contract.

### Task 3: Verify End-to-End Dev Stack Wiring

**Files:**
- Modify: `docker-compose.dev.yml` if verification reveals a real wiring error

- [ ] **Step 1: Bring up the development stack**

Run:

```bash
docker compose -f docker-compose.dev.yml up -d --build
```

Expected: images build and the stack starts, including `nats`, `agents-db`, and `agents-api`.

- [ ] **Step 2: Inspect stack status**

Run:

```bash
docker compose -f docker-compose.dev.yml ps
```

Expected: `agents-db`, `agents-api`, and `nats` are present and running (or `agents-db` reports the normal container health/running state for Postgres).

- [ ] **Step 3: Inspect `agents-api` logs for dependency wiring**

Run:

```bash
docker compose -f docker-compose.dev.yml logs agents-api --tail=200
```

Expected log evidence:

```text
DB host resolves as agents-db
NATS URL points to nats://nats:4222
ingestion starts without hostname/config mismatch errors
```

If external provider credentials block deeper runtime work, that is acceptable. Do not invent a fallback.

- [ ] **Step 4: If runtime wiring fails, make the smallest corrective compose change and re-run verification**

Examples of allowed minimal fixes:

```yaml
depends_on:
  - agents-db
  - nats
```

or correcting a mismatched env key/value such as:

```yaml
DB_HOST: agents-db
NATS_URL: nats://nats:4222
```

Do not broaden scope into unrelated service rewrites.

- [ ] **Step 5: Re-run the final compose verification commands**

Run:

```bash
docker compose -f docker-compose.yml config
docker compose -f docker-compose.dev.yml config
docker compose -f agents/compose.yaml config
docker compose -f docker-compose.dev.yml ps
```

Expected: all config commands succeed and the dev stack status confirms the agents service is wired into the full stack.
