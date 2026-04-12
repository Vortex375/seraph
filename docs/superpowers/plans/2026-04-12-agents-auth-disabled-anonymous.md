# Agents Auth-Disabled Anonymous Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the agents API resolve requests without an auth header to user `anonymous` when `SERAPH_AUTH_ENABLED=false`, matching the existing Seraph auth-disabled behavior so the minimal SPA works in the dev stack.

**Architecture:** Add an explicit auth-enabled setting to the agents service, then centralize the anonymous fallback inside the existing auth dependency instead of teaching the SPA to spoof user identity. Wire the same setting through the compose files so the stack-level behavior matches the backend auth resolution logic.

**Tech Stack:** FastAPI, Pydantic settings, pytest, Docker Compose

---

### Task 1: Add Backend Anonymous Fallback Behavior

**Files:**
- Modify: `agents/app/settings.py`
- Modify: `agents/auth/current_user.py`
- Modify: `agents/tests/test_auth_current_user.py`

- [ ] **Step 1: Write the failing auth-disabled test**

Add this test to `agents/tests/test_auth_current_user.py`:

```python
def test_current_user_defaults_to_anonymous_when_auth_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    app = FastAPI()

    monkeypatch.setenv("SERAPH_AUTH_ENABLED", "false")
    get_settings.cache_clear()

    @app.get("/me")
    async def me(user: AuthenticatedUser = Depends(get_current_user)) -> dict[str, str]:
        return {"user_id": user.user_id}

    client = TestClient(app)
    response = client.get("/me")

    assert response.status_code == 200
    assert response.json() == {"user_id": "anonymous"}

    get_settings.cache_clear()
```

- [ ] **Step 2: Run the auth-disabled test to verify it fails**

Run:

```bash
uv run pytest tests/test_auth_current_user.py -k anonymous -v
```

Expected: FAIL because the current dependency still returns `401` when the header is missing.

- [ ] **Step 3: Add the explicit auth-enabled setting**

Update `agents/app/settings.py` to include:

```python
    seraph_auth_enabled: bool = True
    seraph_auth_user_header: str = "X-Seraph-User"
```

Keep `seraph_auth_user_header` unchanged. Only add the new boolean setting above or beside it.

- [ ] **Step 4: Implement the anonymous fallback in the auth dependency**

Update `agents/auth/current_user.py` to use settings-backed logic like this:

```python
from fastapi import Header, HTTPException, status

from app.settings import get_settings


async def get_current_user(
    x_seraph_user: str | None = Header(default=None, alias="X-Seraph-User"),
) -> AuthenticatedUser:
    user_id = x_seraph_user.strip() if x_seraph_user is not None else None
    if user_id:
        return AuthenticatedUser(user_id=user_id)

    settings = get_settings()
    if not settings.seraph_auth_enabled:
        return AuthenticatedUser(user_id="anonymous")

    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="missing authenticated user")
```

Keep the behavior strict when auth is enabled.

- [ ] **Step 5: Expand auth tests to preserve existing strict behavior**

Ensure `agents/tests/test_auth_current_user.py` still covers:

```python
def test_current_user_reads_seraph_header() -> None: ...

def test_current_user_rejects_blank_seraph_header() -> None: ...
```

Adjust the blank-header test if needed so it explicitly runs with auth enabled by default and still expects:

```python
assert response.status_code == 401
assert response.json() == {"detail": "missing authenticated user"}
```

- [ ] **Step 6: Run the auth test file to verify it passes**

Run:

```bash
uv run pytest tests/test_auth_current_user.py -v
```

Expected: PASS.

### Task 2: Add API-Level Regression Coverage

**Files:**
- Modify: `agents/tests/test_chat_api.py`

- [ ] **Step 1: Write the failing API regression test**

Add this test to `agents/tests/test_chat_api.py`:

```python
def test_create_session_defaults_to_anonymous_when_auth_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SERAPH_AUTH_ENABLED", "false")
    importlib.import_module("app.settings").get_settings.cache_clear()

    app = create_app()

    class StubSession:
        def __init__(self) -> None:
            self.id = "session-1"
            self.user_id = "anonymous"
            self.title = "Anonymous session"
            self.created_at = "2026-04-11T00:00:00Z"
            self.updated_at = "2026-04-11T00:00:00Z"
            self.last_message_at = "2026-04-11T00:00:00Z"

    class StubSessionService:
        def __init__(self, session: object) -> None:
            del session

        async def create_session(self, user_id: str, title: str) -> StubSession:
            assert user_id == "anonymous"
            assert title == "Anonymous session"
            return StubSession()

    monkeypatch.setattr("api.chat.SessionService", StubSessionService)

    with TestClient(app) as client:
        response = client.post("/api/v1/chat/sessions", json={"title": "Anonymous session"})

    assert response.status_code == 201
    assert response.json()["user_id"] == "anonymous"

    importlib.import_module("app.settings").get_settings.cache_clear()
```

- [ ] **Step 2: Run the new API test to verify it fails**

Run:

```bash
uv run pytest tests/test_chat_api.py -k anonymous -v
```

Expected: FAIL before the backend auth fallback exists for headerless requests.

- [ ] **Step 3: Verify the test passes after Task 1 implementation**

Re-run:

```bash
uv run pytest tests/test_chat_api.py -k anonymous -v
```

Expected: PASS.

- [ ] **Step 4: Run the targeted API/auth regression slice**

Run:

```bash
uv run pytest tests/test_auth_current_user.py tests/test_chat_api.py -v
```

Expected: PASS.

### Task 3: Wire Auth-Disabled Mode Through Compose and Verify Stack Behavior

**Files:**
- Modify: `docker-compose.yml`
- Modify: `docker-compose.dev.yml`
- Modify: `agents/compose.yaml`

- [ ] **Step 1: Add `SERAPH_AUTH_ENABLED` to the agents service env blocks**

In each compose file, add this env entry to the agents API service:

```yaml
      SERAPH_AUTH_ENABLED: ${SERAPH_AUTH_ENABLED:-true}
```

For `docker-compose.dev.yml`, set the default to false so the integrated dev stack matches the rest of Seraph's auth-disabled mode:

```yaml
      SERAPH_AUTH_ENABLED: ${SERAPH_AUTH_ENABLED:-false}
```

For the other files, keep the default true unless the file already clearly represents auth-disabled development behavior.

- [ ] **Step 2: Render compose configs to verify the new env is present**

Run:

```bash
docker compose -f docker-compose.yml config
docker compose -f docker-compose.dev.yml config
docker compose -f agents/compose.yaml config
```

Expected: all commands pass and render `SERAPH_AUTH_ENABLED` in the agents service environment.

- [ ] **Step 3: Restart the integrated agents service in the dev stack**

Run:

```bash
docker compose -f docker-compose.dev.yml up -d --build agents-api
```

Expected: `agents-api` rebuilds or restarts successfully.

- [ ] **Step 4: Verify the agents service no longer returns `401` for session creation in auth-disabled mode**

Run:

```bash
curl -i -X POST http://localhost:8000/api/v1/chat/sessions \
  -H 'Content-Type: application/json' \
  --data '{"title":"Anonymous session"}'
```

Expected: not `401 Unauthorized`. A successful result should be `201 Created` with `"user_id":"anonymous"`. If model configuration or some unrelated dependency causes a later failure, the response must still prove the auth layer no longer blocks the request.

- [ ] **Step 5: Verify the agents logs do not show auth-header rejection for headerless session creation**

Run:

```bash
docker logs agentscope-refactor-agents-api-1 --tail 100
```

Expected: no new `401 Unauthorized` entry for the headerless session creation request.
