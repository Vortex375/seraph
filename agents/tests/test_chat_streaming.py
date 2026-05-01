from fastapi.testclient import TestClient
import asyncio
import importlib
from typing import Any, cast
import pytest
import sys
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parents[1]))

from app.main import create_app


@pytest.mark.asyncio
async def test_stream_agent_reply_formats_sse_payload(monkeypatch: pytest.MonkeyPatch) -> None:
    streaming = importlib.import_module("chat.streaming")

    class StubMessage:
        def __init__(self, payload: dict[str, object]) -> None:
            self._payload = payload

        def to_dict(self) -> dict[str, object]:
            return self._payload

    async def fake_stream_printing_messages(*, agents, coroutine_task, **kwargs):
        del agents, kwargs
        coroutine_task.close()
        yield StubMessage({"role": "assistant", "content": "hello"}), True

    monkeypatch.setattr(streaming, "stream_printing_messages", fake_stream_printing_messages)

    chunks: list[str] = []
    async for chunk in streaming.stream_agent_reply(agent=object(), user_input="Hi"):
        chunks.append(chunk)

    assert chunks == ['data: {"role": "assistant", "content": "hello"}\n\n']


@pytest.mark.asyncio
async def test_stream_agent_reply_emits_each_chunk_during_generation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    streaming = importlib.import_module("chat.streaming")

    class StubMessage:
        def __init__(self, payload: dict[str, object]) -> None:
            self._payload = payload

        def to_dict(self) -> dict[str, object]:
            return self._payload

    async def fake_stream_printing_messages(*, agents, coroutine_task, **kwargs):
        del agents, kwargs
        coroutine_task.close()
        yield StubMessage({"id": "assistant-1", "role": "assistant", "content": "p"}), False
        yield StubMessage({"id": "assistant-1", "role": "assistant", "content": "po"}), False
        yield StubMessage({"id": "assistant-1", "role": "assistant", "content": "pon"}), False
        yield StubMessage({"id": "assistant-1", "role": "assistant", "content": "pong"}), True

    monkeypatch.setattr(streaming, "stream_printing_messages", fake_stream_printing_messages)

    chunks: list[str] = []
    async for chunk in streaming.stream_agent_reply(agent=object(), user_input="say pong"):
        chunks.append(chunk)

    assert chunks == [
        'data: {"id": "assistant-1", "role": "assistant", "content": "p"}\n\n',
        'data: {"id": "assistant-1", "role": "assistant", "content": "po"}\n\n',
        'data: {"id": "assistant-1", "role": "assistant", "content": "pon"}\n\n',
        'data: {"id": "assistant-1", "role": "assistant", "content": "pong"}\n\n',
    ]


def test_legacy_message_stream_route_is_removed() -> None:
    with TestClient(create_app()) as client:
        response = client.get(
            "/api/v1/chat/sessions/session-1/stream",
            headers={"X-Seraph-User": "alice"},
        )

    assert response.status_code == 404


@pytest.mark.asyncio
async def test_create_message_and_stream_persists_user_turn_and_streams_reply(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()
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

    with TestClient(app) as client:
        with client.stream(
            "POST",
            "/api/v1/chat/sessions/session-1/messages/stream",
            headers={"X-Seraph-User": "alice"},
            json={"message": "hello"},
        ) as response:
            assert response.status_code == 200
            assert response.headers["content-type"].startswith("text/event-stream")
            payload = "".join(response.iter_text())

    assert recorded["session_id"] == "session-1"
    assert recorded["user_id"] == "alice"
    assert recorded["message"] == "hello"
    assert recorded["request_type"] == "Request"
    assert 'data: {"id":"assistant-1","type":"delta","content":"hello"}' in payload
    assert 'data: {"id":"assistant-1","type":"done"}' in payload


@pytest.mark.asyncio
async def test_stream_message_create_persists_user_message_before_emitting_chunks(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    lifecycle: list[str] = []
    recorded: dict[str, Any] = {}

    async def fake_persist_user_message(*, db: object, session_id: str, user_id: str, message: str) -> str:
        lifecycle.append("persist-user")
        recorded["persist_db"] = db
        recorded["persist_session_id"] = session_id
        recorded["persist_user_id"] = user_id
        recorded["persist_message"] = message
        return "user-1"

    async def fake_run_turn_and_publish(
        *, session_id: str, user_id: str, message: str, request: object, queue: Any
    ) -> None:
        lifecycle.append("run-turn")
        recorded["run_session_id"] = session_id
        recorded["run_user_id"] = user_id
        recorded["run_message"] = message
        recorded["run_request"] = request
        await queue.put('data: {"id":"assistant-1","type":"delta","content":"hello"}\n\n')
        await queue.put('data: {"id":"assistant-1","type":"done"}\n\n')
        await queue.put(None)

    monkeypatch.setattr(chat_module, "_persist_user_message", fake_persist_user_message)
    monkeypatch.setattr(chat_module, "_run_turn_and_publish", fake_run_turn_and_publish)

    db = object()
    request = object()
    chunks: list[str] = []
    async for chunk in chat_module._stream_message_create(
        db=db,
        session_id="session-1",
        user_id="alice",
        message="hello",
        request=request,
    ):
        chunks.append(chunk)

    assert chunks == [
        'data: {"id":"assistant-1","type":"delta","content":"hello"}\n\n',
        'data: {"id":"assistant-1","type":"done"}\n\n',
    ]
    assert lifecycle == ["persist-user", "run-turn"]
    assert recorded["persist_db"] is db
    assert recorded["persist_session_id"] == "session-1"
    assert recorded["persist_user_id"] == "alice"
    assert recorded["persist_message"] == "hello"
    assert recorded["run_request"] is request


@pytest.mark.asyncio
async def test_stream_message_create_updates_session_timestamps_after_persisting_user_message(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    lifecycle: list[str] = []

    async def fake_persist_user_message(*, db: object, session_id: str, user_id: str, message: str) -> str:
        del db, session_id, user_id, message
        lifecycle.append("persist-user")
        return "user-1"

    async def fake_touch_session_activity(*, session_id: str) -> None:
        lifecycle.append(f"touch:{session_id}")

    async def fake_run_turn_and_publish(
        *, session_id: str, user_id: str, message: str, request: object, queue: Any
    ) -> None:
        del session_id, user_id, message, request
        lifecycle.append("run-turn")
        await queue.put(None)

    monkeypatch.setattr(chat_module, "_persist_user_message", fake_persist_user_message)
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

    assert lifecycle == ["persist-user", "touch:session-1", "run-turn"]


@pytest.mark.asyncio
async def test_run_turn_and_publish_tracks_finished_turn_state(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "state_by_id": {}}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
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
        recorded["stream_db"] = db
        recorded["stream_session_id"] = session_id
        recorded["stream_agent"] = agent
        recorded["stream_user_input"] = user_input
        yield 'data: {"id":"assistant-1","content":"hel"}\n\n'
        yield 'data: {"id":"assistant-1","content":"hello"}\n\n'

    async def fake_upsert_turn_state_with_isolated_session(
        *,
        session_id: str,
        user_id: str,
        assistant_message_id: str,
        status: str,
        content: str,
        error: str | None = None,
    ) -> None:
        recorded["state_by_id"][assistant_message_id] = {
            "session_id": session_id,
            "user_id": user_id,
            "assistant_message_id": assistant_message_id,
            "status": status,
            "content": content,
            "error": error,
        }
        recorded["upserts"].append(
            {
                "session_id": session_id,
                "user_id": user_id,
                "assistant_message_id": assistant_message_id,
                "status": status,
                "content": content,
                "error": error,
            }
        )

    async def fake_record_failure_with_isolated_session(*, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded["failure"] = {
            "session_id": session_id,
            "assistant_message_id": assistant_message_id,
            "error": error,
        }

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state_with_isolated_session)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure_with_isolated_session)

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
    assert recorded["stream_db"] is None
    assert recorded["stream_session_id"] == "session-1"
    assert recorded["stream_user_input"] == "hello"
    assert recorded["upserts"] == [
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "running",
            "content": "hel",
            "error": None,
        },
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "running",
            "content": "hello",
            "error": None,
        },
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "finished",
            "content": "hello",
            "error": None,
        },
    ]
    assert recorded["state_by_id"] == {
        "assistant-1": {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "finished",
            "content": "hello",
            "error": None,
        }
    }
    assert "failure" not in recorded
    assert chunks == [
        'data: {"id":"assistant-1","content":"hel"}\n\n',
        'data: {"id":"assistant-1","content":"hello"}\n\n',
        'data: {"id":"assistant-1","type":"done"}\n\n',
    ]


@pytest.mark.asyncio
async def test_run_turn_and_publish_accumulates_true_delta_chunks_in_turn_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "state_by_id": {}}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
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
        recorded["stream_db"] = db
        recorded["stream_session_id"] = session_id
        recorded["stream_agent"] = agent
        recorded["stream_user_input"] = user_input
        yield 'data: {"id":"assistant-1","type":"delta","content":"Hel"}\n\n'
        yield 'data: {"id":"assistant-1","type":"delta","content":"lo"}\n\n'

    async def fake_upsert_turn_state_with_isolated_session(
        *,
        session_id: str,
        user_id: str,
        assistant_message_id: str,
        status: str,
        content: str,
        error: str | None = None,
    ) -> None:
        recorded["state_by_id"][assistant_message_id] = {
            "session_id": session_id,
            "user_id": user_id,
            "assistant_message_id": assistant_message_id,
            "status": status,
            "content": content,
            "error": error,
        }
        recorded["upserts"].append(
            {
                "session_id": session_id,
                "user_id": user_id,
                "assistant_message_id": assistant_message_id,
                "status": status,
                "content": content,
                "error": error,
            }
        )

    async def fake_record_failure_with_isolated_session(*, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded.setdefault("failures", []).append(
            {
                "session_id": session_id,
                "assistant_message_id": assistant_message_id,
                "error": error,
            }
        )

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state_with_isolated_session)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure_with_isolated_session)

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
    assert recorded["stream_db"] is None
    assert recorded["stream_session_id"] == "session-1"
    assert recorded["stream_user_input"] == "hello"
    assert recorded["upserts"] == [
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "running",
            "content": "Hel",
            "error": None,
        },
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "running",
            "content": "Hello",
            "error": None,
        },
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "finished",
            "content": "Hello",
            "error": None,
        },
    ]
    assert recorded["state_by_id"] == {
        "assistant-1": {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "finished",
            "content": "Hello",
            "error": None,
        }
    }
    assert "failures" not in recorded
    assert chunks == [
        'data: {"id":"assistant-1","type":"delta","content":"Hel"}\n\n',
        'data: {"id":"assistant-1","type":"delta","content":"lo"}\n\n',
        'data: {"id":"assistant-1","type":"done"}\n\n',
    ]


@pytest.mark.asyncio
async def test_run_turn_and_publish_updates_session_timestamps_when_turn_finishes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"touches": []}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
            del user_id, session_id
            return object()

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_stream_chat_events(*, db: object, session_id: str, agent: object, user_input: str):
        del db, session_id, agent, user_input
        yield 'data: {"id":"assistant-1","content":"hello"}\n\n'

    async def fake_upsert_turn_state_with_isolated_session(
        *,
        session_id: str,
        user_id: str,
        assistant_message_id: str,
        status: str,
        content: str,
        error: str | None = None,
    ) -> None:
        del session_id, user_id, assistant_message_id, status, content, error

    async def fake_record_failure_with_isolated_session(*, session_id: str, assistant_message_id: str, error: str) -> None:
        del session_id, assistant_message_id, error

    async def fake_touch_session_activity(*, session_id: str) -> None:
        recorded["touches"].append(session_id)

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state_with_isolated_session)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure_with_isolated_session)
    monkeypatch.setattr(chat_module, "_touch_session_activity", fake_touch_session_activity, raising=False)

    queue: asyncio.Queue[str | None] = asyncio.Queue()
    await chat_module._run_turn_and_publish(
        session_id="session-1",
        user_id="alice",
        message="hello",
        request=StubRequest(),
        queue=queue,
    )

    assert recorded["touches"] == ["session-1"]


@pytest.mark.asyncio
async def test_run_turn_and_publish_does_not_reinsert_completed_assistant_message(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
    from agentscope.memory import AsyncSQLAlchemyMemory
    from agentscope.message import Msg
    from documents.models import Base, ChatSession
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    recorded: dict[str, Any] = {"upserts": [], "failures": []}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
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
        recorded["stream_db"] = db
        recorded["stream_session_id"] = session_id
        recorded["stream_agent"] = agent
        recorded["stream_user_input"] = user_input
        yield 'data: {"id":"assistant-1","content":"hello"}\n\n'

    async def fake_upsert_turn_state_with_isolated_session(
        *,
        session_id: str,
        user_id: str,
        assistant_message_id: str,
        status: str,
        content: str,
        error: str | None = None,
    ) -> None:
        recorded["upserts"].append(
            {
                "session_id": session_id,
                "user_id": user_id,
                "assistant_message_id": assistant_message_id,
                "status": status,
                "content": content,
                "error": error,
            }
        )

    async def fake_record_failure_with_isolated_session(*, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded["failures"].append(
            {
                "session_id": session_id,
                "assistant_message_id": assistant_message_id,
                "error": error,
            }
        )

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(sqlalchemy_memory.Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Inbox"))
        memory = AsyncSQLAlchemyMemory(db_session, session_id="session-1", user_id="alice")
        persisted_message = Msg("seraph-documents", "hello", "assistant")
        persisted_message.id = "assistant-1"
        await memory.add(persisted_message, skip_duplicated=False)
        await db_session.commit()

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state_with_isolated_session)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure_with_isolated_session)
    monkeypatch.setattr(chat_module, "SessionLocal", session_factory)

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
    assert recorded["stream_db"] is None
    assert recorded["stream_session_id"] == "session-1"
    assert recorded["stream_user_input"] == "hello"
    assert recorded["upserts"] == [
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "running",
            "content": "hello",
            "error": None,
        },
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "finished",
            "content": "hello",
            "error": None,
        },
    ]
    assert recorded["failures"] == []
    assert chunks == [
        'data: {"id":"assistant-1","content":"hello"}\n\n',
        'data: {"id":"assistant-1","type":"done"}\n\n',
    ]

    await engine.dispose()


@pytest.mark.asyncio
async def test_run_turn_and_publish_waits_for_real_assistant_id_before_persisting_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "state_by_id": {}}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
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
        recorded["stream_db"] = db
        recorded["stream_session_id"] = session_id
        recorded["stream_agent"] = agent
        recorded["stream_user_input"] = user_input
        yield 'data: {"content":"hel"}\n\n'
        yield 'data: {"id":"assistant-1","content":"hello"}\n\n'

    async def fake_upsert_turn_state_with_isolated_session(
        *,
        session_id: str,
        user_id: str,
        assistant_message_id: str,
        status: str,
        content: str,
        error: str | None = None,
    ) -> None:
        recorded["state_by_id"][assistant_message_id] = {
            "session_id": session_id,
            "user_id": user_id,
            "assistant_message_id": assistant_message_id,
            "status": status,
            "content": content,
            "error": error,
        }
        recorded["upserts"].append(
            {
                "session_id": session_id,
                "user_id": user_id,
                "assistant_message_id": assistant_message_id,
                "status": status,
                "content": content,
                "error": error,
            }
        )

    async def fake_record_failure_with_isolated_session(*, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded.setdefault("failures", []).append(
            {
                "session_id": session_id,
                "assistant_message_id": assistant_message_id,
                "error": error,
            }
        )

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state_with_isolated_session)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure_with_isolated_session)

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
    assert recorded["stream_db"] is None
    assert recorded["stream_session_id"] == "session-1"
    assert recorded["stream_user_input"] == "hello"
    assert recorded["upserts"] == [
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "running",
            "content": "hello",
            "error": None,
        },
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "finished",
            "content": "hello",
            "error": None,
        },
    ]
    assert recorded["state_by_id"] == {
        "assistant-1": {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "finished",
            "content": "hello",
            "error": None,
        }
    }
    assert "failures" not in recorded
    assert chunks == [
        'data: {"content":"hel"}\n\n',
        'data: {"id":"assistant-1","content":"hello"}\n\n',
        'data: {"id":"assistant-1","type":"done"}\n\n',
    ]


@pytest.mark.asyncio
async def test_run_turn_and_publish_tracks_failed_turn_state(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "state_by_id": {}}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
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
        del db, session_id, agent, user_input
        yield 'data: {"id":"assistant-1","content":"partial"}\n\n'
        raise RuntimeError("stream failed")

    async def fake_upsert_turn_state_with_isolated_session(
        *,
        session_id: str,
        user_id: str,
        assistant_message_id: str,
        status: str,
        content: str,
        error: str | None = None,
    ) -> None:
        recorded["state_by_id"][assistant_message_id] = {
            "session_id": session_id,
            "user_id": user_id,
            "assistant_message_id": assistant_message_id,
            "status": status,
            "content": content,
            "error": error,
        }
        recorded["upserts"].append(
            {
                "session_id": session_id,
                "user_id": user_id,
                "assistant_message_id": assistant_message_id,
                "status": status,
                "content": content,
                "error": error,
            }
        )

    async def fake_record_failure_with_isolated_session(*, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded["failure"] = {
            "session_id": session_id,
            "assistant_message_id": assistant_message_id,
            "error": error,
        }

    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state_with_isolated_session)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure_with_isolated_session)

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
    assert recorded["upserts"] == [
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "running",
            "content": "partial",
            "error": None,
        },
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "failed",
            "content": "partial",
            "error": "stream failed",
        },
    ]
    assert recorded["state_by_id"] == {
        "assistant-1": {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "failed",
            "content": "partial",
            "error": "stream failed",
        }
    }
    assert recorded["failure"] == {
        "session_id": "session-1",
        "assistant_message_id": "assistant-1",
        "error": "stream failed",
    }
    assert chunks == [
        'data: {"id":"assistant-1","content":"partial"}\n\n',
        'data: {"id":"assistant-1","type":"error","content":"stream failed"}\n\n',
    ]


@pytest.mark.asyncio
async def test_run_turn_and_publish_marks_missing_credentials_setup_failure_as_failed(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "state_by_id": {}, "failures": []}

    class AuthenticationError(Exception):
        pass

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
            recorded["factory_user_id"] = user_id
            recorded["factory_session_id"] = session_id

            class StubKnowledge:
                async def retrieve(self, query: str, limit: int = 5):
                    recorded["knowledge_query"] = query
                    recorded["knowledge_limit"] = limit
                    raise AuthenticationError("You didn't provide an API key")

            class StubAgent:
                def __init__(self) -> None:
                    self.knowledge = [StubKnowledge()]

            return StubAgent()

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_upsert_turn_state_with_isolated_session(
        *,
        session_id: str,
        user_id: str,
        assistant_message_id: str,
        status: str,
        content: str,
        error: str | None = None,
    ) -> None:
        recorded["state_by_id"][assistant_message_id] = {
            "session_id": session_id,
            "user_id": user_id,
            "assistant_message_id": assistant_message_id,
            "status": status,
            "content": content,
            "error": error,
        }
        recorded["upserts"].append(
            {
                "session_id": session_id,
                "user_id": user_id,
                "assistant_message_id": assistant_message_id,
                "status": status,
                "content": content,
                "error": error,
            }
        )

    async def fake_record_failure_with_isolated_session(*, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded["last_failure_assistant_message_id"] = assistant_message_id
        recorded["failures"].append(
            {
                "session_id": session_id,
                "assistant_message_id": assistant_message_id,
                "error": error,
            }
        )

    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state_with_isolated_session)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure_with_isolated_session)

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
    assert recorded["knowledge_query"] == "hello"
    assert recorded["knowledge_limit"] == 5
    assert recorded["upserts"] == [
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": recorded["last_failure_assistant_message_id"],
            "status": "running",
            "content": "Chat streaming is unavailable until OPENAI_API_KEY is configured for agents-api.",
            "error": None,
        },
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": recorded["last_failure_assistant_message_id"],
            "status": "failed",
            "content": "Chat streaming is unavailable until OPENAI_API_KEY is configured for agents-api.",
            "error": "Chat streaming is unavailable until OPENAI_API_KEY is configured for agents-api.",
        },
    ]
    assert recorded["state_by_id"] == {
        recorded["last_failure_assistant_message_id"]: {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": recorded["last_failure_assistant_message_id"],
            "status": "failed",
            "content": "Chat streaming is unavailable until OPENAI_API_KEY is configured for agents-api.",
            "error": "Chat streaming is unavailable until OPENAI_API_KEY is configured for agents-api.",
        }
    }
    assert recorded["failures"] == [
        {
            "session_id": "session-1",
            "assistant_message_id": recorded["last_failure_assistant_message_id"],
            "error": recorded["failures"][0]["error"],
        }
    ]
    assert "api key" in recorded["failures"][0]["error"].lower()
    assert len(chunks) == 1
    assert '"type":"error"' in chunks[0]
    assert "OPENAI_API_KEY" in chunks[0]
    assert '"type":"done"' not in chunks[0]


@pytest.mark.asyncio
async def test_run_turn_and_publish_records_non_credential_stream_failure_once(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "failures": []}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
            recorded["factory_user_id"] = user_id
            recorded["factory_session_id"] = session_id
            return object()

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent, user_input
        yield 'data: {"id":"assistant-1","content":"partial"}\n\n'
        raise RuntimeError("stream failed")

    async def fake_upsert_turn_state_with_isolated_session(
        *,
        session_id: str,
        user_id: str,
        assistant_message_id: str,
        status: str,
        content: str,
        error: str | None = None,
    ) -> None:
        recorded["upserts"].append(
            {
                "session_id": session_id,
                "user_id": user_id,
                "assistant_message_id": assistant_message_id,
                "status": status,
                "content": content,
                "error": error,
            }
        )

    async def fake_record_failure_with_isolated_session(*, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded["failures"].append(
            {
                "session_id": session_id,
                "assistant_message_id": assistant_message_id,
                "error": error,
            }
        )

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state_with_isolated_session)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure_with_isolated_session)

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
    assert recorded["upserts"] == [
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "running",
            "content": "partial",
            "error": None,
        },
        {
            "session_id": "session-1",
            "user_id": "alice",
            "assistant_message_id": "assistant-1",
            "status": "failed",
            "content": "partial",
            "error": "stream failed",
        },
    ]
    assert recorded["failures"] == [
        {
            "session_id": "session-1",
            "assistant_message_id": "assistant-1",
            "error": "stream failed",
        }
    ]
    assert len(chunks) == 2
    assert '"id": "assistant-1"' in chunks[0]
    assert '"content": "partial"' in chunks[0]
    assert '"type":"error"' in chunks[1]
    assert '"content":"stream failed"' in chunks[1]


@pytest.mark.asyncio
async def test_run_turn_and_publish_finishes_queue_when_agent_creation_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"upserts": [], "failures": []}

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
            recorded["factory_user_id"] = user_id
            recorded["factory_session_id"] = session_id
            raise RuntimeError("factory failed")

    class StubState:
        agent_factory = StubAgentFactory()

    class StubApp:
        state = StubState()

    class StubRequest:
        app = StubApp()

    async def fake_upsert_turn_state_with_isolated_session(
        *,
        session_id: str,
        user_id: str,
        assistant_message_id: str,
        status: str,
        content: str,
        error: str | None = None,
    ) -> None:
        recorded["upserts"].append(
            {
                "session_id": session_id,
                "user_id": user_id,
                "assistant_message_id": assistant_message_id,
                "status": status,
                "content": content,
                "error": error,
            }
        )

    async def fake_record_failure_with_isolated_session(*, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded["failures"].append(
            {
                "session_id": session_id,
                "assistant_message_id": assistant_message_id,
                "error": error,
            }
        )

    monkeypatch.setattr(chat_module, "_upsert_turn_state_with_isolated_session", fake_upsert_turn_state_with_isolated_session)
    monkeypatch.setattr(chat_module, "_record_failure_with_isolated_session", fake_record_failure_with_isolated_session)

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
    assert len(recorded["upserts"]) == 1
    assert recorded["upserts"][0]["session_id"] == "session-1"
    assert recorded["upserts"][0]["user_id"] == "alice"
    assert recorded["upserts"][0]["status"] == "failed"
    assert recorded["upserts"][0]["content"] == ""
    assert recorded["upserts"][0]["error"] == "factory failed"
    assert recorded["failures"] == [
        {
            "session_id": "session-1",
            "assistant_message_id": recorded["upserts"][0]["assistant_message_id"],
            "error": "factory failed",
        }
    ]
    assert chunks == [
        (
            f'data: {{"id":"{recorded["upserts"][0]["assistant_message_id"]}",' 
            '"type":"error","content":"factory failed"}\n\n'
        )
    ]


@pytest.mark.asyncio
async def test_stream_chat_events_records_sources(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {}
    knowledge_module = importlib.import_module("knowledge.seraph_knowledge")
    document_module = importlib.import_module("agentscope.rag._document")

    class StubAgent:
        def __init__(self) -> None:
            class StubKnowledge:
                async def retrieve(self, query: str, limit: int = 5):
                    assert query == "hello"
                    assert limit == 5
                    return [
                        knowledge_module.SeraphKnowledgeDocument(
                            id="chunk-1",
                            score=0.9,
                            provenance=knowledge_module.SeraphChunkProvenance(
                                provider_id="provider-a",
                                path="/team/spec.md",
                            ),
                            metadata=document_module.DocMetadata(
                                content={"type": "text", "text": "Path: /team/spec.md\n\nspec excerpt"},
                                doc_id="doc-1",
                                chunk_id=0,
                                total_chunks=1,
                            ),
                        ),
                        {"provider_id": "ignored", "path": "/wrong.md"},
                    ]

            self.knowledge = [StubKnowledge()]

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent, user_input
        yield (
            'data: {"id": "assistant-1", "content": "answer", '
            '"citations": [{"provider_id": "provider-b", "path": "/wrong.md"}]}\n\n'
        )

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        recorded["db"] = db
        recorded["session_id"] = session_id
        recorded["assistant_message_id"] = assistant_message_id
        recorded["sources"] = sources

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            recorded["isolated_db"] = object()
            return recorded["isolated_db"]

        async def __aexit__(self, exc_type, exc, tb) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    chunks: list[str] = []
    claim_db = object()
    agent = StubAgent()
    async for chunk in chat_module._stream_chat_events(
        db=claim_db, session_id="session-1", agent=agent, user_input="hello"
    ):
        chunks.append(chunk)

    assert chunks == [
        'data: {"id": "assistant-1", "content": "answer", '
        '"citations": [{"provider_id": "provider-a", "path": "/team/spec.md", "label": "/team/spec.md"}]}\n\n'
    ]
    assert recorded["db"] is recorded["isolated_db"]
    assert recorded["session_id"] == "session-1"
    assert recorded["assistant_message_id"] == "assistant-1"
    assert recorded["sources"] == [{"provider_id": "provider-a", "path": "/team/spec.md"}]
    assert recorded["db"] is recorded["isolated_db"]
    assert recorded["db"] is not claim_db


@pytest.mark.asyncio
async def test_stream_chat_events_preserves_structured_citations(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")

    class StubKnowledge:
        async def retrieve(self, query: str, limit: int = 5):
            del query, limit
            return []

    class StubAgent:
        def __init__(self) -> None:
            self.knowledge = [StubKnowledge()]
            self._seraph_tool_citations: list[dict[str, str]] = []

    async def fake_stream_agent_reply(*, agent: Any, user_input: str):
        del user_input
        agent._seraph_tool_citations.append(
            {"provider_id": "space-a", "path": "/team/spec.md", "label": "/team/spec.md"}
        )
        yield (
            'data: {"id":"assistant-1","content":"answer","citations":['
            '{"provider_id":"space-a","path":"/team/spec.md","label":"/team/spec.md"}]}'
            "\n\n"
        )

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        del db, session_id, assistant_message_id, sources

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            return object()

        async def __aexit__(self, exc_type, exc, tb) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    chunks: list[str] = []
    async for chunk in chat_module._stream_chat_events(
        db=object(), session_id="session-1", agent=StubAgent(), user_input="hello"
    ):
        chunks.append(chunk)

    assert chunks == [
        'data: {"id": "assistant-1", "content": "answer", '
        '"citations": [{"provider_id": "space-a", "path": "/team/spec.md", "label": "/team/spec.md"}]}\n\n'
    ]


@pytest.mark.asyncio
async def test_stream_chat_events_does_not_persist_untrusted_stream_citations(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {}

    class StubKnowledge:
        async def retrieve(self, query: str, limit: int = 5):
            del query, limit
            return []

    class StubAgent:
        def __init__(self) -> None:
            self.knowledge = [StubKnowledge()]

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent, user_input
        yield (
            'data: {"id":"assistant-1","content":"answer","citations":['
            '{"provider_id":"space-a","path":"/team/spec.md","label":"/team/spec.md"}]}'
            "\n\n"
        )

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        recorded["db"] = db
        recorded["session_id"] = session_id
        recorded["assistant_message_id"] = assistant_message_id
        recorded.setdefault("sources", []).append(sources)

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            recorded["isolated_db"] = object()
            return recorded["isolated_db"]

        async def __aexit__(self, exc_type, exc, tb) -> None:
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

    class StubKnowledge:
        async def retrieve(self, query: str, limit: int = 5):
            del query, limit
            return []

    class StubAgent:
        def __init__(self) -> None:
            self.knowledge = [StubKnowledge()]
            self._seraph_tool_citations: list[dict[str, str]] = []

    async def fake_stream_agent_reply(*, agent: Any, user_input: str):
        del user_input
        agent._seraph_tool_citations.append({"provider_id": "space-a", "path": "/team/spec.md"})
        yield 'data: {"id":"assistant-1","content":"answer","citations":[]}\n\n'

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        recorded["db"] = db
        recorded["session_id"] = session_id
        recorded["assistant_message_id"] = assistant_message_id
        recorded.setdefault("sources", []).append(sources)

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            recorded["isolated_db"] = object()
            return recorded["isolated_db"]

        async def __aexit__(self, exc_type, exc, tb) -> None:
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
        'data: {"id": "assistant-1", "content": "answer", '
        '"citations": [{"provider_id": "space-a", "path": "/team/spec.md", "label": "/team/spec.md"}]}\n\n'
    ]
    assert recorded["sources"] == [[{"provider_id": "space-a", "path": "/team/spec.md"}]]


@pytest.mark.asyncio
async def test_stream_chat_events_restores_preexisting_tool_citations_after_turn(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")

    class StubKnowledge:
        async def retrieve(self, query: str, limit: int = 5):
            del query, limit
            return []

    class StubAgent:
        def __init__(self) -> None:
            self.knowledge = [StubKnowledge()]
            self._seraph_tool_citations = [{"provider_id": "space-a", "path": "/stale.md"}]

    async def fake_stream_agent_reply(*, agent: Any, user_input: str):
        del user_input
        assert agent._seraph_tool_citations == []
        agent._seraph_tool_citations.append({"provider_id": "space-a", "path": "/team/spec.md"})
        yield 'data: {"id":"assistant-1","content":"answer","citations":[]}\n\n'

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        del db, session_id, assistant_message_id, sources

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            return object()

        async def __aexit__(self, exc_type, exc, tb) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    agent = StubAgent()
    async for _chunk in chat_module._stream_chat_events(
        db=object(), session_id="session-1", agent=agent, user_input="hello"
    ):
        pass

    assert agent._seraph_tool_citations == [{"provider_id": "space-a", "path": "/stale.md"}]


@pytest.mark.asyncio
async def test_stream_chat_events_records_sources_again_when_message_id_changes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {}

    class StubKnowledge:
        async def retrieve(self, query: str, limit: int = 5):
            del query, limit
            return []

    class StubAgent:
        def __init__(self) -> None:
            self.knowledge = [StubKnowledge()]
            self._seraph_tool_citations: list[dict[str, str]] = []

    async def fake_stream_agent_reply(*, agent: Any, user_input: str):
        del user_input
        agent._seraph_tool_citations.append({"provider_id": "space-a", "path": "/team/spec.md"})
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

        async def __aexit__(self, exc_type, exc, tb) -> None:
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

    class StubKnowledge:
        async def retrieve(self, query: str, limit: int = 5):
            del query, limit
            return []

    class StubAgent:
        def __init__(self) -> None:
            object.__setattr__(self, "knowledge", [StubKnowledge()])
            object.__setattr__(
                self,
                "_seraph_tool_citations",
                [{"provider_id": "space-a", "path": "/stale.md"}],
            )

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

        async def __aexit__(self, exc_type, exc, tb) -> None:
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
async def test_retrieve_turn_sources_uses_retrieved_knowledge_documents(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    knowledge_module = importlib.import_module("knowledge.seraph_knowledge")
    document_module = importlib.import_module("agentscope.rag._document")

    class StubKnowledge:
        async def retrieve(self, query: str, limit: int = 5):
            assert query == "hello"
            assert limit == 5
            return [
                knowledge_module.SeraphKnowledgeDocument(
                    id="chunk-1",
                    score=0.9,
                    provenance=knowledge_module.SeraphChunkProvenance(
                        provider_id="provider-a",
                        path="/team/spec.md",
                    ),
                    metadata=document_module.DocMetadata(
                        content={"type": "text", "text": "Path: /team/spec.md\n\nspec excerpt"},
                        doc_id="doc-1",
                        chunk_id=0,
                        total_chunks=1,
                    ),
                ),
            ]

    class StubAgent:
        def __init__(self) -> None:
            self.knowledge = [StubKnowledge()]

    sources = await chat_module._retrieve_turn_sources(StubAgent(), "hello")

    assert sources == [{"provider_id": "provider-a", "path": "/team/spec.md"}]


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
    source = cast(Any, added_sources[0])
    failure = cast(Any, added_failures[0])

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


@pytest.mark.asyncio
async def test_stream_chat_events_records_failures(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, str] = {}

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent, user_input
        raise RuntimeError("assistant id=assistant-9 boom")
        yield ""

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

        async def __aexit__(self, exc_type, exc, tb) -> None:
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

    class StubKnowledge:
        async def retrieve(self, query: str, limit: int = 5):
            assert query == "hello"
            assert limit == 5
            raise AuthenticationError("You didn't provide an API key")

    class StubAgent:
        def __init__(self) -> None:
            self.knowledge = [StubKnowledge()]

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

        async def __aexit__(self, exc_type, exc, tb) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "record_failure", fake_record_failure)
    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    chunks: list[str] = []
    async for chunk in chat_module._stream_chat_events(
        db=object(), session_id="session-1", agent=StubAgent(), user_input="hello"
    ):
        chunks.append(chunk)

    assert len(chunks) == 1
    assert '"role": "assistant"' in chunks[0]
    assert '"type": "error"' in chunks[0]
    assert "OPENAI_API_KEY" in chunks[0]
    assert recorded["session_id"] == "session-1"
    assert "api key" in recorded["error"].lower()
    assert recorded["db_id"] == recorded["isolated_db_id"]
