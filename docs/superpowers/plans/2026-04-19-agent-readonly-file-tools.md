# Agent Read-Only File Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add read-only agent tools for file search, directory listing, metadata inspection, and bounded file reads, plus structured chat citations that open files in the Flutter viewer.

**Architecture:** Add a small file-access layer inside `agents` that reuses `SpacesClient`, the existing NATS search contract, and the Python file-provider client. Extend chat citations to a structured file-reference model, then update Flutter chat rendering to navigate into the existing `FileViewerView` route.

**Tech Stack:** Python/FastAPI/AgentScope/NATS, Go search services, Flutter/GetX/Dio

---

## File Map

- Create: `agents/chat/file_models.py`
  Purpose: shared typed file reference / metadata / tool result models
- Create: `agents/chat/file_access.py`
  Purpose: scope validation, file listing/stat/reading helpers using `SpacesClient` + `FileProviderClient`
- Create: `agents/chat/search_client.py`
  Purpose: NATS-backed file search client that mirrors the existing search request/reply contract
- Modify: `agents/chat/agent_factory.py`
  Purpose: register read-only tools on the agent toolkit and wire dependencies
- Modify: `agents/chat/prompts.py`
  Purpose: instruct the agent when to use knowledge vs file tools and to cite linked files
- Modify: `agents/app/main.py`
  Purpose: construct and inject the new search/file-access dependencies
- Modify: `agents/api/models.py`
  Purpose: extend chat citation responses from strings to structured objects
- Modify: `agents/api/chat.py`
  Purpose: emit structured file citations for live stream and stored history
- Modify: `agents/chat/session_service.py`
  Purpose: return structured citations from stored chat history
- Create: `agents/tests/test_file_access.py`
  Purpose: scope enforcement, stat/list/read behavior, binary and size bounds
- Create: `agents/tests/test_search_client.py`
  Purpose: NATS search request/reply behavior and normalization
- Modify: `agents/tests/test_chat_api.py`
  Purpose: structured citation serialization coverage
- Modify: `agents/tests/test_chat_streaming.py`
  Purpose: structured streamed citation coverage
- Modify: `agents/tests/test_app_bootstrap.py`
  Purpose: dependency wiring coverage if startup changes need it
- Modify: `app/seraph_app/lib/src/chat/chat_models.dart`
  Purpose: typed file citation model with backward-compatible parsing
- Modify: `app/seraph_app/lib/src/chat/chat_controller.dart`
  Purpose: preserve structured citations from SSE/history
- Modify: `app/seraph_app/lib/src/chat/chat_widgets.dart`
  Purpose: render citations as tappable rows
- Create: `app/seraph_app/lib/src/chat/chat_navigation.dart`
  Purpose: centralize chat citation to file-viewer route conversion
- Modify: `app/seraph_app/test/chat/chat_service_test.dart`
  Purpose: parse structured citation payloads
- Modify: `app/seraph_app/test/chat/chat_controller_test.dart`
  Purpose: stream/history structured citation coverage
- Modify: `app/seraph_app/test/chat/chat_view_test.dart`
  Purpose: citation tap opens file viewer route

### Task 1: Build The Agents Search Client

**Files:**
- Create: `agents/chat/search_client.py`
- Test: `agents/tests/test_search_client.py`

- [ ] **Step 1: Write the failing tests**

```python
import json

import pytest

from chat.search_client import AgentSearchClient


@pytest.mark.asyncio
async def test_search_client_collects_file_hits_from_ack_and_reply_flow() -> None:
    published: list[tuple[str, bytes]] = []
    ack_messages = [
        type("Msg", (), {"data": json.dumps({
            "requestId": "req-1",
            "replyId": "reply-1",
            "ack": True,
            "types": ["files"],
        }).encode("utf-8")})(),
    ]
    reply_messages = [
        type("Msg", (), {"data": json.dumps({
            "requestId": "req-1",
            "replyId": "reply-1",
            "type": "files",
            "reply": {"providerId": "space-a", "path": "docs/spec.md"},
            "last": False,
        }).encode("utf-8")})(),
        type("Msg", (), {"data": json.dumps({
            "requestId": "req-1",
            "replyId": "reply-1",
            "last": True,
        }).encode("utf-8")})(),
    ]

    class StubSubscription:
        def __init__(self, messages):
            self._messages = iter(messages)

        async def next_msg(self):
            return next(self._messages)

        async def unsubscribe(self) -> None:
            return None

    class StubNats:
        def __init__(self) -> None:
            self._subjects: list[str] = []

        async def subscribe(self, subject: str):
            self._subjects.append(subject)
            if subject.endswith(".ack"):
                return StubSubscription(ack_messages)
            return StubSubscription(reply_messages)

        async def publish(self, subject: str, payload: bytes) -> None:
            published.append((subject, payload))

    client = AgentSearchClient(nc=StubNats(), request_id_factory=lambda: "req-1")

    hits = await client.search_files(user_id="alice", query="spec")

    assert len(hits) == 1
    assert hits[0].provider_id == "space-a"
    assert hits[0].path == "/docs/spec.md"
    assert json.loads(published[0][1].decode("utf-8")) == {
        "requestId": "req-1",
        "userId": "alice",
        "query": "spec",
        "types": ["files"],
    }


@pytest.mark.asyncio
async def test_search_client_ignores_non_file_replies_and_errors_cleanly() -> None:
    class StubSubscription:
        def __init__(self, messages):
            self._messages = iter(messages)

        async def next_msg(self):
            return next(self._messages)

        async def unsubscribe(self) -> None:
            return None

    class StubNats:
        async def subscribe(self, subject: str):
            if subject.endswith(".ack"):
                return StubSubscription([
                    type("Msg", (), {"data": b'{"requestId":"req-1","replyId":"reply-1","ack":true}'})(),
                ])
            return StubSubscription([
                type("Msg", (), {"data": b'{"requestId":"req-1","replyId":"reply-1","type":"other","reply":{},"last":false}'})(),
                type("Msg", (), {"data": b'{"requestId":"req-1","replyId":"reply-1","error":"boom","last":false}'})(),
                type("Msg", (), {"data": b'{"requestId":"req-1","replyId":"reply-1","last":true}'})(),
            ])

        async def publish(self, subject: str, payload: bytes) -> None:
            del subject, payload

    client = AgentSearchClient(nc=StubNats(), request_id_factory=lambda: "req-1")

    with pytest.raises(RuntimeError, match="boom"):
        await client.search_files(user_id="alice", query="spec")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest agents/tests/test_search_client.py -v`
Expected: FAIL with `ModuleNotFoundError` or `ImportError` for `chat.search_client`

- [ ] **Step 3: Write minimal implementation**

```python
from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass
from typing import Any, Callable

SEARCH_REQUEST_TOPIC = "seraph.search"
SEARCH_ACK_TOPIC_PATTERN = "seraph.search.%s.ack"
SEARCH_REPLY_TOPIC_PATTERN = "seraph.search.%s.reply"


@dataclass(frozen=True)
class SearchFileHit:
    provider_id: str
    path: str


class AgentSearchClient:
    def __init__(self, nc: Any, request_id_factory: Callable[[], str]) -> None:
        self._nc = nc
        self._request_id_factory = request_id_factory

    async def search_files(self, *, user_id: str, query: str) -> list[SearchFileHit]:
        request_id = self._request_id_factory()
        ack_sub = await self._nc.subscribe(SEARCH_ACK_TOPIC_PATTERN % request_id)
        reply_sub = await self._nc.subscribe(SEARCH_REPLY_TOPIC_PATTERN % request_id)
        try:
            payload = {
                "requestId": request_id,
                "userId": user_id,
                "query": query,
                "types": ["files"],
            }
            await self._nc.publish(SEARCH_REQUEST_TOPIC, json.dumps(payload).encode("utf-8"))

            await ack_sub.next_msg()
            hits: list[SearchFileHit] = []
            while True:
                msg = await reply_sub.next_msg()
                reply = json.loads(msg.data.decode("utf-8"))
                if reply.get("error"):
                    raise RuntimeError(str(reply["error"]))
                if reply.get("last"):
                    return hits
                if reply.get("type") != "files":
                    continue
                data = reply.get("reply", {})
                provider_id = str(data.get("providerId", "")).strip()
                path = "/" + str(data.get("path", "")).strip().lstrip("/")
                if provider_id and path != "/":
                    hits.append(SearchFileHit(provider_id=provider_id, path=path))
        finally:
            await ack_sub.unsubscribe()
            await reply_sub.unsubscribe()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest agents/tests/test_search_client.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add agents/chat/search_client.py agents/tests/test_search_client.py
git commit -m "feat: add agents file search client"
```

### Task 2: Build The Read-Only File Access Service

**Files:**
- Create: `agents/chat/file_models.py`
- Create: `agents/chat/file_access.py`
- Test: `agents/tests/test_file_access.py`

- [ ] **Step 1: Write the failing tests**

```python
import pytest

from chat.file_access import AgentFileAccessService
from spaces.access import SpaceScope


@pytest.mark.asyncio
async def test_list_directory_rejects_path_outside_scope() -> None:
    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            assert user_id == "alice"
            return [SpaceScope(provider_id="space-a", path_prefix="/team")]

    service = AgentFileAccessService(spaces_client=StubSpacesClient(), file_provider_factory=lambda provider_id: None, search_client=None)

    with pytest.raises(PermissionError):
        await service.list_directory(user_id="alice", provider_id="space-a", path="/private")


@pytest.mark.asyncio
async def test_stat_and_list_directory_return_normalized_metadata() -> None:
    class StubDirHandle:
        async def readdir(self, count: int):
            del count
            return [
                type("Info", (), {"name": "spec.md", "size": 12, "mod_time": 123, "is_dir": False})(),
                type("Info", (), {"name": "notes", "size": 0, "mod_time": 456, "is_dir": True})(),
            ]

        async def close(self) -> None:
            return None

    class StubFileProvider:
        async def stat(self, path: str):
            assert path == "/team"
            return type("Info", (), {"name": "team", "size": 0, "mod_time": 999, "is_dir": True})()

        async def open_file(self, path: str, flag: int, perm: int):
            del flag, perm
            assert path == "/team"
            return StubDirHandle()

    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            return [SpaceScope(provider_id="space-a", path_prefix="/team")]

    service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(),
        search_client=None,
    )

    stat_result = await service.stat_file(user_id="alice", provider_id="space-a", path="/team")
    list_result = await service.list_directory(user_id="alice", provider_id="space-a", path="/team")

    assert stat_result.path == "/team"
    assert stat_result.is_dir is True
    assert [entry.path for entry in list_result] == ["/team/spec.md", "/team/notes"]


@pytest.mark.asyncio
async def test_read_file_excerpt_returns_text_and_rejects_binary_or_large_files() -> None:
    class StubFile:
        async def read(self, size: int) -> bytes:
            assert size == 32
            return b"hello from seraph"

        async def close(self) -> None:
            return None

    class StubBinaryFile(StubFile):
        async def read(self, size: int) -> bytes:
            del size
            return b"\xff\xfe\x00\x01"

    class StubFileProvider:
        def __init__(self, size: int, reader_cls: type[StubFile]):
            self._size = size
            self._reader_cls = reader_cls

        async def stat(self, path: str):
            return type("Info", (), {"name": "spec.txt", "size": self._size, "mod_time": 1, "is_dir": False})()

        async def open_file(self, path: str, flag: int, perm: int):
            del path, flag, perm
            return self._reader_cls()

    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            return [SpaceScope(provider_id="space-a", path_prefix="/team")]

    service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(12, StubFile),
        search_client=None,
        max_read_bytes=32,
        max_inline_file_size=128,
    )

    result = await service.read_file_excerpt(user_id="alice", provider_id="space-a", path="/team/spec.txt")
    assert result.content == "hello from seraph"

    binary_service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(12, StubBinaryFile),
        search_client=None,
        max_read_bytes=32,
        max_inline_file_size=128,
    )
    binary_result = await binary_service.read_file_excerpt(user_id="alice", provider_id="space-a", path="/team/spec.bin")
    assert binary_result.content is None
    assert "can’t read" in binary_result.message

    large_service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(1024, StubFile),
        search_client=None,
        max_read_bytes=32,
        max_inline_file_size=128,
    )
    large_result = await large_service.read_file_excerpt(user_id="alice", provider_id="space-a", path="/team/spec.txt")
    assert large_result.content is None
    assert "too large" in large_result.message
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest agents/tests/test_file_access.py -v`
Expected: FAIL with import errors for `chat.file_access`

- [ ] **Step 3: Write minimal implementation**

```python
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any, Callable


@dataclass(frozen=True)
class AgentFileReference:
    provider_id: str
    path: str
    label: str


@dataclass(frozen=True)
class AgentFileEntry:
    provider_id: str
    path: str
    name: str
    size: int
    mod_time: int
    is_dir: bool


@dataclass(frozen=True)
class AgentFileReadResult:
    reference: AgentFileReference
    content: str | None
    message: str | None


class AgentFileAccessService:
    def __init__(
        self,
        *,
        spaces_client: Any,
        file_provider_factory: Callable[[str], Any],
        search_client: Any,
        max_read_bytes: int = 4096,
        max_inline_file_size: int = 262144,
    ) -> None:
        self._spaces_client = spaces_client
        self._file_provider_factory = file_provider_factory
        self._search_client = search_client
        self._max_read_bytes = max_read_bytes
        self._max_inline_file_size = max_inline_file_size

    async def stat_file(self, *, user_id: str, provider_id: str, path: str) -> AgentFileEntry:
        normalized = await self._normalize_and_authorize(user_id=user_id, provider_id=provider_id, path=path)
        client = self._file_provider_factory(provider_id)
        info = await client.stat(normalized)
        return AgentFileEntry(provider_id=provider_id, path=normalized, name=info.name, size=info.size, mod_time=info.mod_time, is_dir=info.is_dir)

    async def list_directory(self, *, user_id: str, provider_id: str, path: str) -> list[AgentFileEntry]:
        normalized = await self._normalize_and_authorize(user_id=user_id, provider_id=provider_id, path=path)
        client = self._file_provider_factory(provider_id)
        handle = await client.open_file(normalized, os.O_RDONLY, 0)
        try:
            entries = await handle.readdir(0)
        finally:
            await handle.close()
        return [
            AgentFileEntry(
                provider_id=provider_id,
                path=self._join_child(normalized, entry.name),
                name=entry.name,
                size=entry.size,
                mod_time=entry.mod_time,
                is_dir=entry.is_dir,
            )
            for entry in entries
        ]

    async def read_file_excerpt(self, *, user_id: str, provider_id: str, path: str) -> AgentFileReadResult:
        normalized = await self._normalize_and_authorize(user_id=user_id, provider_id=provider_id, path=path)
        client = self._file_provider_factory(provider_id)
        info = await client.stat(normalized)
        reference = AgentFileReference(provider_id=provider_id, path=normalized, label=normalized)
        if info.is_dir:
            return AgentFileReadResult(reference=reference, content=None, message="That path is a directory.")
        if info.size > self._max_inline_file_size:
            return AgentFileReadResult(reference=reference, content=None, message="That file is too large to read inline.")
        handle = await client.open_file(normalized, os.O_RDONLY, 0)
        try:
            payload = await handle.read(self._max_read_bytes)
        finally:
            await handle.close()
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError:
            return AgentFileReadResult(reference=reference, content=None, message="I can inspect metadata but can’t read that file as text.")
        return AgentFileReadResult(reference=reference, content=text, message=None)

    async def _normalize_and_authorize(self, *, user_id: str, provider_id: str, path: str) -> str:
        normalized = self._normalize_path(path)
        scopes = await self._spaces_client.get_scopes_for_user(user_id)
        for scope in scopes:
            if scope.provider_id != provider_id:
                continue
            prefix = self._normalize_path(scope.path_prefix)
            if normalized == prefix or normalized.startswith(prefix.rstrip("/") + "/"):
                return normalized
        raise PermissionError("requested path is outside accessible scopes")

    def _normalize_path(self, path: str) -> str:
        normalized = path if path.startswith("/") else f"/{path}"
        parts: list[str] = []
        for part in PurePosixPath(normalized).parts:
            if part in ("", "/", "."):
                continue
            if part == "..":
                raise PermissionError("path escapes root")
            parts.append(part)
        return "/" + "/".join(parts) if parts else "/"

    def _join_child(self, parent: str, child: str) -> str:
        return self._normalize_path(f"{parent.rstrip('/')}/{child}")
```

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest agents/tests/test_file_access.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add agents/chat/file_models.py agents/chat/file_access.py agents/tests/test_file_access.py
git commit -m "feat: add read-only agents file access"
```

### Task 3: Wire Agent Tools And Prompt Guidance

**Files:**
- Modify: `agents/chat/agent_factory.py`
- Modify: `agents/chat/prompts.py`
- Modify: `agents/app/main.py`
- Test: `agents/tests/test_app_bootstrap.py`

- [ ] **Step 1: Write the failing test**

```python
import importlib


def test_agent_factory_registers_read_only_file_tools(monkeypatch):
    module = importlib.import_module("chat.agent_factory")
    recorded = {}

    class StubToolkit:
        def __init__(self) -> None:
            self.tools = []

        def add_tool(self, tool):
            self.tools.append(tool)

    class StubAgent:
        def __init__(self, **kwargs):
            recorded.update(kwargs)

    monkeypatch.setattr(module, "Toolkit", StubToolkit)
    monkeypatch.setattr(module, "ReActAgent", StubAgent)

    factory = module.AgentFactory(
        engine=object(),
        chat_model_name="gpt-test",
        api_key=None,
        base_url=None,
        embedding_model=object(),
        retrieval_service=object(),
        spaces_client=object(),
        search_client=object(),
        file_access_service_factory=lambda user_id: object(),
    )

    factory.create("alice", "session-1")

    toolkit = recorded["toolkit"]
    assert len(toolkit.tools) == 4
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest agents/tests/test_app_bootstrap.py -k register_read_only_file_tools -v`
Expected: FAIL because `AgentFactory` does not yet accept the new dependencies or register tools

- [ ] **Step 3: Write minimal implementation**

```python
class AgentFactory:
    def __init__(
        self,
        engine: Any,
        chat_model_name: str,
        api_key: str | None,
        base_url: str | None,
        embedding_model: Any,
        retrieval_service: Any,
        spaces_client: Any,
        search_client: Any,
        file_access_service_factory: Any,
    ) -> None:
        ...
        self._search_client = search_client
        self._file_access_service_factory = file_access_service_factory

    def create(self, user_id: str, session_id: str) -> ReActAgent:
        toolkit = Toolkit()
        file_access = self._file_access_service_factory(user_id)
        toolkit.add_tool(lambda query: file_access.search_files(user_id=user_id, query=query))
        toolkit.add_tool(lambda provider_id, path: file_access.list_directory(user_id=user_id, provider_id=provider_id, path=path))
        toolkit.add_tool(lambda provider_id, path: file_access.stat_file(user_id=user_id, provider_id=provider_id, path=path))
        toolkit.add_tool(lambda provider_id, path: file_access.read_file_excerpt(user_id=user_id, provider_id=provider_id, path=path))
        return ReActAgent(..., toolkit=toolkit, ...)
```

Update `DOCUMENT_CHAT_PROMPT` so it tells the model:

```python
DOCUMENT_CHAT_PROMPT = """You are Seraph's document assistant.

Use retrieved document context first.
If the answer depends on file names, folder contents, file metadata, or non-indexed files, use the available read-only file tools.
Never claim to have modified files or suggest that you can write, rename, move, or delete them.
When you reference a concrete file, include the citation returned by the tool or retrieval context.
If relevant information is not available, say so clearly.
"""
```

Update `RuntimeAgentFactory` construction in `agents/app/main.py` to create and pass the search client and file-access service factory.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest agents/tests/test_app_bootstrap.py -k register_read_only_file_tools -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add agents/chat/agent_factory.py agents/chat/prompts.py agents/app/main.py agents/tests/test_app_bootstrap.py
git commit -m "feat: register read-only file tools for agents"
```

### Task 4: Emit Structured Citations From Agents Chat APIs

**Files:**
- Modify: `agents/api/models.py`
- Modify: `agents/api/chat.py`
- Modify: `agents/chat/session_service.py`
- Modify: `agents/tests/test_chat_api.py`
- Modify: `agents/tests/test_chat_streaming.py`

- [ ] **Step 1: Write the failing tests**

```python
def test_chat_message_response_supports_structured_citations() -> None:
    from api.models import ChatMessageResponse

    response = ChatMessageResponse(
        id="assistant-1",
        role="assistant",
        content="See spec",
        created_at="2026-04-19T00:00:00Z",
        citations=[{"provider_id": "space-a", "path": "/team/spec.md", "label": "/team/spec.md"}],
    )

    assert response.citations[0]["provider_id"] == "space-a"


@pytest.mark.asyncio
async def test_stream_chat_events_preserves_structured_citations(monkeypatch):
    chat_module = importlib.import_module("api.chat")

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent, user_input
        yield 'data: {"id":"assistant-1","content":"answer","citations":[{"provider_id":"space-a","path":"/team/spec.md","label":"/team/spec.md"}]}\n\n'

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    chunks = []
    async for chunk in chat_module._stream_chat_events(db=object(), session_id="session-1", agent=object(), user_input="hello"):
        chunks.append(chunk)

    assert '"provider_id": "space-a"' in chunks[0]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `uv run pytest agents/tests/test_chat_api.py agents/tests/test_chat_streaming.py -k structured_citations -v`
Expected: FAIL because citations are currently typed as `list[str]`

- [ ] **Step 3: Write minimal implementation**

```python
class FileCitationResponse(BaseModel):
    provider_id: str
    path: str
    label: str


class ChatMessageResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: str
    role: str
    content: str
    created_at: datetime
    citations: list[FileCitationResponse]
```

Map stored path-only citations into structured objects in `session_service.py`:

```python
def _path_to_citation(path: str) -> dict[str, str]:
    return {"provider_id": "", "path": path, "label": path}
```

In `api/chat.py`, preserve already-structured citations from stream payloads and normalize legacy path strings into the same object form before yielding responses.

- [ ] **Step 4: Run test to verify it passes**

Run: `uv run pytest agents/tests/test_chat_api.py agents/tests/test_chat_streaming.py -k structured_citations -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add agents/api/models.py agents/api/chat.py agents/chat/session_service.py agents/tests/test_chat_api.py agents/tests/test_chat_streaming.py
git commit -m "feat: add structured agents chat citations"
```

### Task 5: Update Flutter Chat Models And Navigation

**Files:**
- Create: `app/seraph_app/lib/src/chat/chat_navigation.dart`
- Modify: `app/seraph_app/lib/src/chat/chat_models.dart`
- Modify: `app/seraph_app/lib/src/chat/chat_controller.dart`
- Modify: `app/seraph_app/lib/src/chat/chat_widgets.dart`
- Modify: `app/seraph_app/test/chat/chat_service_test.dart`
- Modify: `app/seraph_app/test/chat/chat_controller_test.dart`
- Modify: `app/seraph_app/test/chat/chat_view_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
test('ChatMessage parses structured citations and preserves legacy strings', () {
  final message = ChatMessage.fromJson({
    'id': 'assistant-1',
    'role': 'assistant',
    'content': 'See the spec',
    'created_at': '2026-04-19T00:00:00Z',
    'citations': [
      {
        'provider_id': 'space-a',
        'path': '/team/spec.md',
        'label': '/team/spec.md',
      },
      '/legacy/path.txt',
    ],
  });

  expect(message.citations[0].providerId, 'space-a');
  expect(message.citations[1].path, '/legacy/path.txt');
});

testWidgets('assistant citations open the file viewer route when tapped', (tester) async {
  // pump ChatView with one assistant message containing a structured citation
  // tap the citation row
  // verify navigator pushed '/view?path=space-a/team/spec.md'
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/chat/chat_service_test.dart test/chat/chat_controller_test.dart test/chat/chat_view_test.dart`
Expected: FAIL because citations are still `List<String>` and not tappable

- [ ] **Step 3: Write minimal implementation**

```dart
class ChatCitation {
  ChatCitation({
    required this.providerId,
    required this.path,
    required this.label,
  });

  final String? providerId;
  final String path;
  final String label;

  factory ChatCitation.fromJson(dynamic json) {
    if (json is String) {
      return ChatCitation(providerId: null, path: json, label: json);
    }

    final map = json as Map<String, dynamic>;
    return ChatCitation(
      providerId: map['provider_id'] as String?,
      path: map['path'] as String,
      label: (map['label'] as String?) ?? (map['path'] as String),
    );
  }

  String get viewerPath {
    if (providerId == null || providerId!.isEmpty) {
      return path;
    }
    return '${providerId!}${path.startsWith('/') ? path : '/$path'}';
  }
}
```

Render citations as tappable list tiles:

```dart
ListTile(
  contentPadding: EdgeInsets.zero,
  title: Text(citation.label),
  dense: true,
  onTap: () => openChatCitation(citation),
)
```

And centralize navigation in `chat_navigation.dart`:

```dart
void openChatCitation(ChatCitation citation) {
  Get.toNamed('${FileViewerView.routeName}?path=${Uri.encodeComponent(citation.viewerPath)}');
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/chat/chat_service_test.dart test/chat/chat_controller_test.dart test/chat/chat_view_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/seraph_app/lib/src/chat/chat_navigation.dart app/seraph_app/lib/src/chat/chat_models.dart app/seraph_app/lib/src/chat/chat_controller.dart app/seraph_app/lib/src/chat/chat_widgets.dart app/seraph_app/test/chat/chat_service_test.dart app/seraph_app/test/chat/chat_controller_test.dart app/seraph_app/test/chat/chat_view_test.dart
git commit -m "feat: add linked chat file citations"
```

### Task 6: Verify The End-To-End Slice

**Files:**
- Modify as needed from previous tasks

- [ ] **Step 1: Run focused agents test suites**

Run: `uv run pytest agents/tests/test_search_client.py agents/tests/test_file_access.py agents/tests/test_chat_api.py agents/tests/test_chat_streaming.py agents/tests/test_app_bootstrap.py -v`
Expected: PASS

- [ ] **Step 2: Run API gateway verification**

Run: `go test ./...`
Workdir: `api-gateway`
Expected: existing `search` failures may still reproduce; if unchanged from baseline, document them and confirm no new failures in touched code

- [ ] **Step 3: Run Flutter chat tests**

Run: `flutter test test/chat/chat_service_test.dart test/chat/chat_controller_test.dart test/chat/chat_view_test.dart`
Expected: PASS

- [ ] **Step 4: Review git diff before completion**

Run: `git diff --stat main...HEAD`
Expected: shows only the agent file-tool and chat citation changes described in the spec

- [ ] **Step 5: Commit**

```bash
git add agents app/seraph_app
git commit -m "feat: add read-only agent file access"
```
