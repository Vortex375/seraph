# Agents Database Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the agents service initialize its SQLAlchemy schema on startup so a fresh dev stack can create chat sessions without manual database setup.

**Architecture:** Add one startup-time schema initialization step to the FastAPI lifespan using the existing SQLAlchemy `Base.metadata.create_all` on the configured async engine. Verify this with a focused bootstrap regression test and a live dev-stack session-creation check.

**Tech Stack:** FastAPI lifespan, SQLAlchemy async engine, pytest, Docker Compose

---

### Task 1: Add Startup-Time Schema Initialization

**Files:**
- Modify: `agents/app/main.py`
- Modify: `agents/tests/test_app_bootstrap.py`

- [ ] **Step 1: Write the failing startup bootstrap test**

Add a test to `agents/tests/test_app_bootstrap.py` that proves app startup invokes schema creation. Use a monkeypatched fake engine transaction and fake metadata object so the test verifies the startup path, not a real database.

The intended test shape is:

```python
def test_app_startup_initializes_database_schema(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    calls: list[str] = []

    class DummyConn:
        async def run_sync(self, fn):
            calls.append("run_sync")
            fn("sync-conn")

    class DummyBegin:
        async def __aenter__(self):
            calls.append("begin")
            return DummyConn()

        async def __aexit__(self, exc_type, exc, tb):
            calls.append("end")

    class DummyEngine:
        def begin(self):
            return DummyBegin()

    class DummyMetadata:
        def create_all(self, bind):
            calls.append(f"create_all:{bind}")

    monkeypatch.setattr(app_main, "engine", DummyEngine())
    monkeypatch.setattr(importlib.import_module("documents.models").Base, "metadata", DummyMetadata())

    app = create_app()
    with TestClient(app):
        pass

    assert calls == ["begin", "run_sync", "create_all:sync-conn", "end"]
```

- [ ] **Step 2: Run the bootstrap test to verify it fails**

Run:

```bash
uv run pytest tests/test_app_bootstrap.py -k schema -v
```

Expected: FAIL because startup does not currently create the schema.

- [ ] **Step 3: Implement startup-time schema creation**

In `agents/app/main.py`, import the declarative base and add a helper such as:

```python
from documents.models import Base


async def initialize_database_schema() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
```

Call it during lifespan startup before the service begins handling requests, for example before ingestion startup:

```python
    app.state.settings = get_settings()
    await initialize_database_schema()
    ingestion_service = create_ingestion_service(app.state.settings)
```

Keep the change minimal. Do not add a separate migration framework.

- [ ] **Step 4: Run the bootstrap tests to verify they pass**

Run:

```bash
uv run pytest tests/test_app_bootstrap.py -v
```

Expected: PASS.

### Task 2: Verify the Fix in the Live Dev Stack

**Files:**
- Modify: `docker-compose.dev.yml` only if verification exposes a real new issue

- [ ] **Step 1: Rebuild and restart the agents service**

Run:

```bash
docker compose -f docker-compose.dev.yml up -d --build agents-api
```

Expected: `agents-api` rebuilds and restarts successfully.

- [ ] **Step 2: Verify the agents logs show clean startup**

Run:

```bash
docker logs agentscope-refactor-agents-api-1 --tail 120
```

Expected: startup completes without `UndefinedTable` errors during idle startup.

- [ ] **Step 3: Verify anonymous session creation succeeds**

Run:

```bash
curl -i -X POST http://localhost:8000/api/v1/chat/sessions \
  -H 'Content-Type: application/json' \
  --data '{"title":"Anonymous session"}'
```

Expected:

```http
HTTP/1.1 201 Created
```

and the JSON body includes:

```json
{"user_id":"anonymous"}
```

- [ ] **Step 4: If the session request still fails, inspect the smallest relevant log evidence and fix only the newly exposed bootstrap issue**

Allowed follow-up evidence gathering:

```bash
docker logs agentscope-refactor-agents-api-1 --tail 200
```

Do not widen scope into unrelated chat/runtime features unless they are directly exposed by the bootstrap fix path.
