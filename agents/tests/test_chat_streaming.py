import asyncio
import importlib
import sys
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

sys.path.append(str(Path(__file__).resolve().parents[1]))

from app.main import create_app


def _app() -> Any:
    return create_app()


class _StubReplyStart:
    def __init__(self, reply_id: str) -> None:
        self.reply_id = reply_id


class _StubTextDelta:
    def __init__(self, delta: str) -> None:
        self.delta = delta


class _StubToolResult:
    def __init__(self, state: Any) -> None:
        self.state = state


class _StubReplyEnd:
    pass


async def _async_noop(**kwargs: Any) -> None:
    return None


@pytest.mark.asyncio
async def test_stream_agent_reply_formats_sse_payload(monkeypatch: pytest.MonkeyPatch) -> None:
    streaming = importlib.import_module("chat.streaming")
    monkeypatch.setattr(streaming, "ReplyStartEvent", _StubReplyStart)
    monkeypatch.setattr(streaming, "TextBlockDeltaEvent", _StubTextDelta)
    monkeypatch.setattr(streaming, "ReplyEndEvent", _StubReplyEnd)

    class StubAgent:
        async def reply_stream(self, _msg: object) -> Any:
            yield _StubReplyStart(reply_id="assistant-1")
            yield _StubTextDelta(delta="hello")
            yield _StubReplyEnd()

    chunks: list[str] = []
    async for chunk in streaming.stream_agent_reply(agent=StubAgent(), user_input="Hi"):
        chunks.append(chunk)

    assert chunks == [
        'data: {"id": "assistant-1", "role": "assistant", "type": "delta", "content": "hello"}\n\n',
        'data: {"id": "assistant-1", "role": "assistant", "type": "done"}\n\n',
    ]


@pytest.mark.asyncio
async def test_stream_agent_reply_emits_each_chunk_during_generation(monkeypatch: pytest.MonkeyPatch) -> None:
    streaming = importlib.import_module("chat.streaming")
    monkeypatch.setattr(streaming, "ReplyStartEvent", _StubReplyStart)
    monkeypatch.setattr(streaming, "TextBlockDeltaEvent", _StubTextDelta)
    monkeypatch.setattr(streaming, "ReplyEndEvent", _StubReplyEnd)

    class StubAgent:
        async def reply_stream(self, _msg: object) -> Any:
            yield _StubReplyStart(reply_id="assistant-1")
            yield _StubTextDelta(delta="p")
            yield _StubTextDelta(delta="po")
            yield _StubTextDelta(delta="pon")
            yield _StubReplyEnd()

    chunks: list[str] = []
    async for chunk in streaming.stream_agent_reply(agent=StubAgent(), user_input="say pong"):
        chunks.append(chunk)

    assert chunks == [
        'data: {"id": "assistant-1", "role": "assistant", "type": "delta", "content": "p"}\n\n',
        'data: {"id": "assistant-1", "role": "assistant", "type": "delta", "content": "po"}\n\n',
        'data: {"id": "assistant-1", "role": "assistant", "type": "delta", "content": "pon"}\n\n',
        'data: {"id": "assistant-1", "role": "assistant", "type": "done"}\n\n',
    ]


@pytest.mark.asyncio
async def test_stream_agent_reply_collects_tool_citations_from_toolkit(monkeypatch: pytest.MonkeyPatch) -> None:
    streaming = importlib.import_module("chat.streaming")
    monkeypatch.setattr(streaming, "ReplyStartEvent", _StubReplyStart)
    monkeypatch.setattr(streaming, "TextBlockDeltaEvent", _StubTextDelta)
    monkeypatch.setattr(streaming, "ToolResultEndEvent", _StubToolResult)
    monkeypatch.setattr(streaming, "ReplyEndEvent", _StubReplyEnd)

    class _ToolResultState:
        SUCCESS = 0

    monkeypatch.setattr(streaming, "ToolResultState", _ToolResultState)

    class StubTool:
        def __init__(self, citations: list[dict[str, str]]) -> None:
            self._citations = citations

    class StubToolGroup:
        def __init__(self, tools: list[StubTool]) -> None:
            self.tools = tools

    class StubToolkit:
        def __init__(self, groups: list[StubToolGroup]) -> None:
            self.tool_groups = groups

    class StubAgent:
        def __init__(self) -> None:
            self.toolkit = StubToolkit(
                [
                    StubToolGroup([StubTool([{
                        "provider_id": "space-a",
                        "path": "/team/spec.md",
                        "label": "/team/spec.md",
                    }])]),
                ]
            )

        async def reply_stream(self, _msg: object) -> Any:
            yield _StubReplyStart(reply_id="assistant-1")
            yield _StubTextDelta(delta="hi")
            yield _StubToolResult(state=_ToolResultState.SUCCESS)
            yield _StubReplyEnd()

    agent = StubAgent()
    chunks: list[str] = []
    async for chunk in streaming.stream_agent_reply(agent=agent, user_input="Hi"):
        chunks.append(chunk)

    assert len(chunks) == 2
    assert getattr(agent, "_seraph_tool_citations", []) == [
        {"provider_id": "space-a", "path": "/team/spec.md", "label": "/team/spec.md"},
    ]


def test_legacy_message_stream_route_is_removed() -> None:
    client = TestClient(_app())
    try:
        response = client.get(
            "/api/v1/chat/sessions/session-1/stream",
            headers={"X-Seraph-User": "alice"},
        )
    finally:
        client.close()

    assert response.status_code == 404


@pytest.mark.asyncio
async def test_create_message_and_stream_endpoint_invokes_stream_create(monkeypatch: pytest.MonkeyPatch) -> None:
    recorded: dict[str, Any] = {}

    class StubSession:
        def __init__(self, session_id: str, user_id: str, title: str) -> None:
            self.id = session_id
            self.user_id = user_id
            self.title = title
            self.created_at = "2026-04-11T00:00:00Z"
            self.updated_at = "2026-04-11T00:00:00Z"
            self.last_message_at = "2026-04-11T00:00:00Z"

    class StubSessionService:
        def __init__(self, session: object) -> None:
            del session

        async def get_session(self, user_id: str, session_id: str) -> StubSession | None:
            if user_id != "alice" or session_id != "session-1":
                return None
            return StubSession(session_id, user_id, "Inbox")

    async def fake_stream_message_create(*, db: object, session_id: str, user_id: str, message: str, request: object):
        recorded["db"] = db
        recorded["session_id"] = session_id
        recorded["user_id"] = user_id
        recorded["message"] = message
        recorded["request_type"] = type(request).__name__
        yield 'data: {"id":"assistant-1","type":"delta","content":"hello"}\n\n'
        yield 'data: {"id":"assistant-1","type":"done"}\n\n'

    monkeypatch.setattr("api.chat.SessionService", StubSessionService)
    monkeypatch.setattr("api.chat._stream_message_create", fake_stream_message_create)

    client = TestClient(_app())
    try:
        with client.stream(
            "POST",
            "/api/v1/chat/sessions/session-1/messages/stream",
            headers={"X-Seraph-User": "alice"},
            json={"message": "hello"},
        ) as response:
            assert response.status_code == 200
            assert response.headers["content-type"].startswith("text/event-stream")
            payload = "".join(response.iter_text())
    finally:
        client.close()

    assert recorded["session_id"] == "session-1"
    assert recorded["user_id"] == "alice"
    assert recorded["message"] == "hello"
    assert recorded["request_type"] == "Request"
    assert 'data: {"id":"assistant-1","type":"delta","content":"hello"}' in payload
    assert 'data: {"id":"assistant-1","type":"done"}' in payload



@pytest.mark.asyncio
async def test_stream_message_create_updates_session_timestamps_before_turn(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    lifecycle: list[str] = []

    async def fake_touch_session_activity(*, session_id: str) -> None:
        lifecycle.append(f"touch:{session_id}")

    async def fake_run_turn_and_publish(**kwargs: Any) -> None:
        lifecycle.append("run-turn")
        queue = kwargs["queue"]
        await queue.put(None)

    monkeypatch.setattr(chat_module, "_touch_session_activity", fake_touch_session_activity, raising=False)
    monkeypatch.setattr(chat_module, "_run_turn_and_publish", fake_run_turn_and_publish)

    async for _chunk in chat_module._stream_message_create(
        db=object(),
        session_id="session-1",
        user_id="alice",
        message="hello",
        request=object(),
    ):
        pass

    assert lifecycle == ["touch:session-1", "run-turn"]


@pytest.mark.asyncio
async def test_run_turn_and_publish_tracks_finished_turn_state(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "state_by_id": {}}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str, *, state: object = None) -> object:
            recorded["factory_user_id"] = user_id
            recorded["factory_session_id"] = session_id
            return object()

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_stream_chat_events(*, db: object, session_id: str, agent: object, user_input: str):
        recorded["stream_session_id"] = session_id
        recorded["stream_agent"] = agent
        recorded["stream_user_input"] = user_input
        yield 'data: {"id":"assistant-1","content":"hel"}\n\n'
        yield 'data: {"id":"assistant-1","content":"hello"}\n\n'

    async def fake_upsert_turn_state(**kwargs: Any) -> None:
        recorded["state_by_id"][kwargs["assistant_message_id"]] = kwargs.copy()
        recorded["upserts"].append(kwargs.copy())

    async def fake_record_failure(**kwargs: Any) -> None:
        recorded["failure"] = kwargs.copy()

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure)
    monkeypatch.setattr(chat_module, "_touch_session_activity", _async_noop, raising=False)

    queue: asyncio.Queue[str | None] = asyncio.Queue()
    await chat_module._run_turn_and_publish(
        session_id="session-1",
        user_id="alice",
        message="hello",
        request=StubRequest(),
        queue=queue,
    )

    chunks: list[str] = []
    while True:
        chunk = await queue.get()
        if chunk is None:
            break
        chunks.append(chunk)

    assert recorded["factory_user_id"] == "alice"
    assert recorded["factory_session_id"] == "session-1"
    assert recorded["stream_session_id"] == "session-1"
    assert recorded["stream_user_input"] == "hello"
    assert recorded["state_by_id"]["assistant-1"]["status"] == "finished"
    assert recorded["state_by_id"]["assistant-1"]["content"] == "hello"
    assert "failure" not in recorded
    assert chunks == [
        'data: {"id":"assistant-1","content":"hel"}\n\n',
        'data: {"id":"assistant-1","content":"hello"}\n\n',
        'data: {"id":"assistant-1","type":"done"}\n\n',
    ]


@pytest.mark.asyncio
async def test_run_turn_and_publish_accumulates_delta_chunks_in_turn_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": []}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str, *, state: object = None) -> object:
            del user_id, session_id, state
            return object()

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_stream_chat_events(**kwargs: Any):
        yield 'data: {"id":"assistant-1","type":"delta","content":"Hel"}\n\n'
        yield 'data: {"id":"assistant-1","type":"delta","content":"lo"}\n\n'

    async def fake_upsert_turn_state(**kwargs: Any) -> None:
        recorded["upserts"].append({"status": kwargs["status"], "content": kwargs["content"]})

    async def fake_record_failure(**kwargs: Any) -> None:
        recorded["failure"] = kwargs

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure)
    monkeypatch.setattr(chat_module, "_touch_session_activity", _async_noop, raising=False)

    queue: asyncio.Queue[str | None] = asyncio.Queue()
    await chat_module._run_turn_and_publish(
        session_id="session-1",
        user_id="alice",
        message="hello",
        request=StubRequest(),
        queue=queue,
    )

    while True:
        chunk = await queue.get()
        if chunk is None:
            break

    assert recorded["upserts"] == [
        {"status": "running", "content": "Hel"},
        {"status": "running", "content": "Hello"},
        {"status": "finished", "content": "Hello"},
    ]
    assert "failure" not in recorded


@pytest.mark.asyncio
async def test_run_turn_and_publish_updates_session_timestamps_when_turn_finishes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"touches": []}

    class StubAgentFactory:
        def create(self, *args: Any, **kwargs: Any) -> object:
            del args, kwargs
            return object()

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_stream_chat_events(**kwargs: Any):
        yield 'data: {"id":"assistant-1","content":"hello"}\n\n'

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", _async_noop)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", _async_noop)
    monkeypatch.setattr(chat_module, "_touch_session_activity", lambda *, session_id: recorded["touches"].append(session_id), raising=False)

    queue: asyncio.Queue[str | None] = asyncio.Queue()
    await chat_module._run_turn_and_publish(
        session_id="session-1",
        user_id="alice",
        message="hello",
        request=StubRequest(),
        queue=queue,
    )

    while True:
        if await queue.get() is None:
            break

    assert recorded["touches"] == ["session-1"]


@pytest.mark.asyncio
async def test_run_turn_and_publish_tracks_failed_turn_state(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "state_by_id": {}}

    class StubAgentFactory:
        def create(self, *args: Any, **kwargs: Any) -> object:
            del args, kwargs
            return object()

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_stream_chat_events(**kwargs: Any):
        yield 'data: {"id":"assistant-1","content":"partial"}\n\n'
        raise RuntimeError("stream failed")

    async def fake_upsert_turn_state(**kwargs: Any) -> None:
        recorded["state_by_id"][kwargs["assistant_message_id"]] = dict(kwargs)
        recorded["upserts"].append(dict(kwargs))

    async def fake_record_failure(**kwargs: Any) -> None:
        recorded["failure"] = dict(kwargs)

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure)

    queue: asyncio.Queue[str | None] = asyncio.Queue()
    await chat_module._run_turn_and_publish(
        session_id="session-1",
        user_id="alice",
        message="hello",
        request=StubRequest(),
        queue=queue,
    )

    chunks: list[str] = []
    while True:
        chunk = await queue.get()
        if chunk is None:
            break
        chunks.append(chunk)

    assert recorded["state_by_id"]["assistant-1"]["status"] == "failed"
    assert recorded["state_by_id"]["assistant-1"]["content"] == "partial"
    assert recorded["state_by_id"]["assistant-1"]["error"] == "stream failed"
    assert recorded["failure"]["assistant_message_id"] == "assistant-1"
    assert '"type":"error"' in chunks[-1]


@pytest.mark.asyncio
async def test_run_turn_and_publish_records_non_credential_stream_failure_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "failures": []}

    class StubAgentFactory:
        def create(self, *args: Any, **kwargs: Any) -> object:
            del args, kwargs
            return object()

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_stream_chat_events(**kwargs: Any):
        yield 'data: {"id":"assistant-1","content":"partial"}\n\n'
        exc = RuntimeError("stream failed")
        setattr(exc, "_seraph_failure_recorded", True)
        raise exc

    async def fake_upsert_turn_state(**kwargs: Any) -> None:
        recorded["upserts"].append({"status": kwargs["status"], "error": kwargs.get("error")})

    async def fake_record_failure(**kwargs: Any) -> None:
        recorded["failures"].append(dict(kwargs))

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure)
    monkeypatch.setattr(chat_module, "_touch_session_activity", _async_noop, raising=False)

    queue: asyncio.Queue[str | None] = asyncio.Queue()
    await chat_module._run_turn_and_publish(
        session_id="session-1",
        user_id="alice",
        message="hello",
        request=StubRequest(),
        queue=queue,
    )

    while True:
        if await queue.get() is None:
            break

    assert recorded["upserts"][-1]["status"] == "failed"
    assert recorded["upserts"][-1]["error"] == "stream failed"
    assert recorded["failures"] == []


@pytest.mark.asyncio
async def test_run_turn_and_publish_handles_missing_api_key_setup_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "failures": []}

    class AuthenticationError(Exception):
        pass

    class StubAgentFactory:
        def create(self, *args: Any, **kwargs: Any) -> object:
            del args, kwargs
            raise AuthenticationError("You didn't provide an API key")

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_upsert_turn_state(**kwargs: Any) -> None:
        recorded["upserts"].append(dict(kwargs))

    async def fake_record_failure(**kwargs: Any) -> None:
        recorded["failures"].append(dict(kwargs))

    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure)

    queue: asyncio.Queue[str | None] = asyncio.Queue()
    await chat_module._run_turn_and_publish(
        session_id="session-1",
        user_id="alice",
        message="hello",
        request=StubRequest(),
        queue=queue,
    )

    chunks: list[str] = []
    while True:
        chunk = await queue.get()
        if chunk is None:
            break
        chunks.append(chunk)

    assert recorded["upserts"][-1]["status"] == "failed"
    assert "api key" in recorded["upserts"][-1]["error"].lower()
    assert recorded["failures"] == []
    assert len(chunks) == 1
    assert '"type":"error"' in chunks[0]
    assert "api key" in chunks[0].lower()


@pytest.mark.asyncio
async def test_run_turn_and_publish_finishes_queue_when_agent_creation_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "failures": []}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str, *, state: object = None) -> object:
            recorded["factory_user_id"] = user_id
            recorded["factory_session_id"] = session_id
            raise RuntimeError("factory failed")

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_upsert_turn_state(**kwargs: Any) -> None:
        recorded["upserts"].append(dict(kwargs))

    async def fake_record_failure(**kwargs: Any) -> None:
        recorded["failures"].append(dict(kwargs))

    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure)

    queue: asyncio.Queue[str | None] = asyncio.Queue()
    await chat_module._run_turn_and_publish(
        session_id="session-1",
        user_id="alice",
        message="hello",
        request=StubRequest(),
        queue=queue,
    )

    chunks: list[str] = []
    while True:
        chunk = await queue.get()
        if chunk is None:
            break
        chunks.append(chunk)

    assert recorded["factory_user_id"] == "alice"
    assert recorded["factory_session_id"] == "session-1"
    assert recorded["upserts"][0]["status"] == "failed"
    assert recorded["upserts"][0]["error"] == "factory failed"
    assert len(recorded["failures"]) == 1
    assert chunks == [
        f'data: {{"id":"{recorded["upserts"][0]["assistant_message_id"]}",'
        '"type":"error","content":"factory failed"}\n\n'
    ]


@pytest.mark.asyncio
async def test_stream_chat_events_records_tool_citations(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {}

    class StubAgent:
        pass

    async def fake_stream_agent_reply(*, agent: Any, user_input: str):
        del user_input
        agent._seraph_tool_citations = [{
            "provider_id": "space-a",
            "path": "/team/spec.md",
        }]
        yield 'data: {"id":"assistant-1","content":"answer","citations":[]}\n\n'

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        recorded["session_id"] = session_id
        recorded["assistant_message_id"] = assistant_message_id
        recorded["sources"] = sources

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            recorded["isolated_db"] = object()
            return recorded["isolated_db"]

        async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    chunks: list[str] = []
    async for chunk in chat_module._stream_chat_events(
        db=object(), session_id="session-1", agent=StubAgent(), user_input="hello"
    ):
        chunks.append(chunk)

    assert chunks == [
        'data: {"id": "assistant-1", "content": "answer", "citations": [{"provider_id": "space-a", "path": "/team/spec.md", "label": "/team/spec.md"}]}\n\n',
    ]
    assert recorded["session_id"] == "session-1"
    assert recorded["assistant_message_id"] == "assistant-1"
    assert recorded["sources"] == [{"provider_id": "space-a", "path": "/team/spec.md"}]


@pytest.mark.asyncio
async def test_stream_chat_events_ignores_untrusted_stream_citations(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {}

    class StubAgent:
        pass

    async def fake_stream_agent_reply(*, agent: Any, user_input: str):
        del agent, user_input
        yield (
            'data: {"id":"assistant-1","content":"answer","citations":['
            '{"provider_id":"space-a","path":"/team/spec.md","label":"/team/spec.md"}]}\n\n'
        )

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        recorded["sources"] = sources

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            return object()

        async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    chunks: list[str] = []
    async for chunk in chat_module._stream_chat_events(
        db=object(), session_id="session-1", agent=StubAgent(), user_input="hello"
    ):
        chunks.append(chunk)

    assert chunks == ['data: {"id": "assistant-1", "content": "answer", "citations": []}\n\n']
    assert "sources" not in recorded


@pytest.mark.asyncio
async def test_stream_chat_events_persists_validated_tool_citations(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {}

    class StubAgent:
        pass

    async def fake_stream_agent_reply(*, agent: Any, user_input: str):
        del user_input
        agent._seraph_tool_citations = [{
            "provider_id": "space-a",
            "path": "/team/spec.md",
        }]
        yield 'data: {"id":"assistant-1","content":"answer","citations":[]}\n\n'

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        recorded["sources"] = sources

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            return object()

        async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    agent = StubAgent()
    chunks: list[str] = []
    async for chunk in chat_module._stream_chat_events(
        db=object(), session_id="session-1", agent=agent, user_input="hello"
    ):
        chunks.append(chunk)

    assert chunks == [
        'data: {"id": "assistant-1", "content": "answer", "citations": [{"provider_id": "space-a", "path": "/team/spec.md", "label": "/team/spec.md"}]}\n\n'
    ]
    assert recorded["sources"] == [{"provider_id": "space-a", "path": "/team/spec.md"}]


@pytest.mark.asyncio
async def test_stream_chat_events_restores_preexisting_tool_citations_after_turn(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")

    class StubAgent:
        def __init__(self) -> None:
            self._seraph_tool_citations = [{"provider_id": "space-a", "path": "/stale.md"}]

    async def fake_stream_agent_reply(*, agent: Any, user_input: str):
        del user_input
        agent._seraph_tool_citations = [{"provider_id": "space-a", "path": "/team/spec.md"}]
        yield 'data: {"id":"assistant-1","content":"answer","citations":[]}\n\n'

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "_record_sources_with_isolated_session", _async_noop)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", _async_noop)

    agent = StubAgent()
    async for _chunk in chat_module._stream_chat_events(
        db=object(), session_id="session-1", agent=agent, user_input="hello"
    ):
        pass

    assert agent._seraph_tool_citations == [{"provider_id": "space-a", "path": "/stale.md"}]


@pytest.mark.asyncio
async def test_stream_chat_events_records_sources_again_when_message_id_changes(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {}

    class StubAgent:
        pass

    async def fake_stream_agent_reply(*, agent: Any, user_input: str):
        del user_input
        agent._seraph_tool_citations = [{"provider_id": "space-a", "path": "/team/spec.md"}]
        yield 'data: {"id":"assistant-1","content":"first","citations":[]}\n\n'
        yield 'data: {"id":"assistant-2","content":"second","citations":[]}\n\n'

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        del db, session_id
        recorded.setdefault("calls", []).append((assistant_message_id, sources))

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            return object()

        async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    chunks: list[str] = []
    async for chunk in chat_module._stream_chat_events(
        db=object(), session_id="session-1", agent=StubAgent(), user_input="hello"
    ):
        chunks.append(chunk)

    assert len(chunks) == 2
    assert recorded["calls"] == [
        ("assistant-1", [{"provider_id": "space-a", "path": "/team/spec.md"}]),
        ("assistant-2", [{"provider_id": "space-a", "path": "/team/spec.md"}]),
    ]


@pytest.mark.asyncio
async def test_stream_chat_events_ignores_stale_tool_citations_when_agent_attribute_is_not_writable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {}

    class StubAgent:
        def __init__(self) -> None:
            object.__setattr__(self, "_seraph_tool_citations", [{"provider_id": "space-a", "path": "/stale.md"}])

        def __setattr__(self, name: str, value: object) -> None:
            if name == "_seraph_tool_citations":
                raise AttributeError("read only")
            object.__setattr__(self, name, value)

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent, user_input
        yield 'data: {"id":"assistant-1","content":"answer","citations":[]}\n\n'

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        del db, session_id, assistant_message_id
        recorded.setdefault("sources", []).append(sources)

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            return object()

        async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    chunks: list[str] = []
    async for chunk in chat_module._stream_chat_events(
        db=object(), session_id="session-1", agent=StubAgent(), user_input="hello"
    ):
        chunks.append(chunk)

    assert chunks == ['data: {"id": "assistant-1", "content": "answer", "citations": []}\n\n']
    assert "sources" not in recorded


@pytest.mark.asyncio
async def test_stream_chat_events_records_failures(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, str] = {}

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent, user_input
        yield ""
        raise RuntimeError("assistant id=assistant-9 boom")

    async def fake_record_failure(db: object, *, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded["db_id"] = str(id(db))
        recorded["session_id"] = session_id
        recorded["assistant_message_id"] = assistant_message_id
        recorded["error"] = error

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_failure", fake_record_failure)

    class StubContextManager:
        async def __aenter__(self) -> object:
            db = object()
            recorded["isolated_db_id"] = str(id(db))
            return db

        async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    with pytest.raises(RuntimeError, match="assistant id=assistant-9 boom"):
        async for _chunk in chat_module._stream_chat_events(
            db=object(), session_id="session-1", agent=object(), user_input="hello"
        ):
            pass

    assert recorded["session_id"] == "session-1"
    assert recorded["assistant_message_id"] == "assistant-9"
    assert recorded["error"] == "assistant id=assistant-9 boom"
    assert recorded["db_id"] == recorded["isolated_db_id"]


@pytest.mark.asyncio
async def test_stream_chat_events_yields_error_chunk_for_missing_api_key(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, str] = {}

    class AuthenticationError(Exception):
        pass

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent, user_input
        if False:
            yield ""
        raise AuthenticationError("You didn't provide an API key")

    async def fake_record_failure(db: object, *, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded["db_id"] = str(id(db))
        recorded["session_id"] = session_id
        recorded["assistant_message_id"] = assistant_message_id
        recorded["error"] = error

    class StubContextManager:
        async def __aenter__(self) -> object:
            db = object()
            recorded["isolated_db_id"] = str(id(db))
            return db

        async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_failure", fake_record_failure)
    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    chunks: list[str] = []
    async for chunk in chat_module._stream_chat_events(
        db=object(), session_id="session-1", agent=object(), user_input="hello"
    ):
        chunks.append(chunk)

    assert len(chunks) == 1
    assert '"role": "assistant"' in chunks[0]
    assert '"type": "error"' in chunks[0]
    assert "OPENAI_API_KEY" in chunks[0]
    assert recorded["session_id"] == "session-1"
    assert "api key" in recorded["error"].lower()
    assert recorded["db_id"] == recorded["isolated_db_id"]


@pytest.mark.asyncio
async def test_record_sources_is_idempotent_and_record_failure_recovers() -> None:
    citations = importlib.import_module("chat.citations")
    operations: list[tuple[str, Any]] = []

    class StubExisting:
        def __init__(self, provider_id: str, path: str) -> None:
            self.provider_id = provider_id
            self.path = path

    class StubScalars:
        def all(self) -> list[StubExisting]:
            return [StubExisting("provider-a", "/team/spec.md")]

    class StubResult:
        def scalars(self) -> StubScalars:
            return StubScalars()

    class StubDb:
        def __init__(self) -> None:
            self.commit_attempts = 0

        async def execute(self, statement: object) -> StubResult:
            operations.append(("execute", statement))
            return StubResult()

        def add(self, obj: object) -> None:
            operations.append(("add", obj))

        async def commit(self) -> None:
            self.commit_attempts += 1
            if self.commit_attempts == 1:
                raise RuntimeError("duplicate write")
            operations.append(("commit", self.commit_attempts))

        async def rollback(self) -> None:
            operations.append(("rollback", self.commit_attempts))

    db = StubDb()

    with pytest.raises(RuntimeError, match="duplicate write"):
        await citations.record_sources(
            db,
            session_id="session-1",
            assistant_message_id="assistant-1",
            sources=[
                {"provider_id": "provider-a", "path": "/team/spec.md"},
                {"provider_id": "provider-a", "path": "/team/spec.md"},
                {"provider_id": "provider-b", "path": "/team/other.md"},
            ],
        )

    await citations.record_failure(db, session_id="session-1", assistant_message_id="assistant-1", error="boom")

    added_sources = [obj for op, obj in operations if op == "add" and obj.__class__.__name__ == "ChatTurnSource"]
    added_failures = [obj for op, obj in operations if op == "add" and obj.__class__.__name__ == "ChatTurnFailure"]
    source = added_sources[0]
    failure = added_failures[0]

    assert len(added_sources) == 1
    assert source.provider_id == "provider-b"
    assert failure.error == "boom"
    assert [op for op, _ in operations].count("rollback") >= 2


@pytest.mark.asyncio
async def test_record_failure_rolls_back_when_commit_fails() -> None:
    citations = importlib.import_module("chat.citations")
    operations: list[str] = []

    class StubDb:
        async def rollback(self) -> None:
            operations.append("rollback")

        def add(self, obj: object) -> None:
            del obj
            operations.append("add")

        async def commit(self) -> None:
            operations.append("commit")
            raise RuntimeError("commit failed")

    db = StubDb()

    with pytest.raises(RuntimeError, match="commit failed"):
        await citations.record_failure(db, session_id="session-1", assistant_message_id="assistant-1", error="boom")

    assert operations == ["rollback", "add", "commit", "rollback"]


@pytest.mark.asyncio
async def test_record_sources_rolls_back_when_commit_is_cancelled() -> None:
    citations = importlib.import_module("chat.citations")
    operations: list[str] = []

    class StubScalars:
        def all(self) -> list[object]:
            return []

    class StubResult:
        def scalars(self) -> StubScalars:
            return StubScalars()

    class StubDb:
        async def execute(self, statement: object) -> StubResult:
            del statement
            operations.append("execute")
            return StubResult()

        def add(self, obj: object) -> None:
            del obj
            operations.append("add")

        async def commit(self) -> None:
            operations.append("commit")
            raise asyncio.CancelledError()

        async def rollback(self) -> None:
            operations.append("rollback")

    db = StubDb()

    with pytest.raises(asyncio.CancelledError):
        await citations.record_sources(
            db,
            session_id="session-1",
            assistant_message_id="assistant-1",
            sources=[{"provider_id": "provider-a", "path": "/team/spec.md"}],
        )

    assert operations == ["execute", "add", "commit", "rollback"]


@pytest.mark.asyncio
async def test_record_failure_rolls_back_when_commit_is_cancelled() -> None:
    citations = importlib.import_module("chat.citations")
    operations: list[str] = []

    class StubDb:
        async def rollback(self) -> None:
            operations.append("rollback")

        def add(self, obj: object) -> None:
            del obj
            operations.append("add")

        async def commit(self) -> None:
            operations.append("commit")
            raise asyncio.CancelledError()

    db = StubDb()

    with pytest.raises(asyncio.CancelledError):
        await citations.record_failure(db, session_id="session-1", assistant_message_id="assistant-1", error="boom")

    assert operations == ["rollback", "add", "commit", "rollback"]
