from datetime import datetime, timezone
from types import SimpleNamespace

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from chat.session_service import SessionService
from db.session import _build_async_db_url, get_postgres_db
from documents.models import Base, ChatSession, ChatTurnState


@pytest.mark.asyncio
async def test_create_session_belongs_to_request_user() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        service = SessionService(db_session)
        session = await service.create_session(user_id="alice", title="Inbox")

    assert session.user_id == "alice"
    assert session.title == "Inbox"

    await engine.dispose()


@pytest.mark.asyncio
async def test_list_sessions_returns_sidebar_summary_fields() -> None:
    import importlib

    sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
    message_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.MessageTable
    session_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.SessionTable
    user_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.UserTable

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(sqlalchemy_memory.Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Roadmap Review"))
        db_session.add(user_table(id="alice"))
        db_session.add(session_table(id="session-1", user_id="alice"))
        db_session.add(
            message_table(
                id="assistant-row-1",
                session_id="session-1",
                index=1,
                msg={
                    "id": "assistant-1",
                    "role": "assistant",
                    "content": [{"type": "text", "text": "First line\nFinal preview line"}],
                    "timestamp": "2026-04-12T00:00:01",
                },
            )
        )
        db_session.add(
            ChatTurnState(
                id="turn-state-1",
                session_id="session-1",
                user_id="alice",
                assistant_message_id="assistant-running-1",
                status="running",
                content="Still running",
            )
        )
        await db_session.commit()

        service = SessionService(db_session)
        sessions = await service.list_sessions("alice")

    assert len(sessions) == 1
    assert sessions[0].headline == "Roadmap Review"
    assert sessions[0].preview == "Still running"
    assert sessions[0].status == "running"

    await engine.dispose()


@pytest.mark.asyncio
async def test_list_sessions_ignores_hidden_retrieval_messages_for_preview() -> None:
    import importlib

    sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
    message_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.MessageTable
    session_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.SessionTable
    user_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.UserTable

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(sqlalchemy_memory.Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Roadmap Review"))
        db_session.add(user_table(id="alice"))
        db_session.add(session_table(id="session-1", user_id="alice"))
        db_session.add(
            message_table(
                id="user-row-1",
                session_id="session-1",
                index=1,
                msg={
                    "id": "user-1",
                    "role": "user",
                    "content": [{"type": "text", "text": "<retrieved_knowledge>hidden context</retrieved_knowledge>"}],
                    "timestamp": "2026-04-12T00:00:00",
                },
            )
        )
        db_session.add(
            message_table(
                id="assistant-row-1",
                session_id="session-1",
                index=2,
                msg={
                    "id": "assistant-1",
                    "role": "assistant",
                    "content": [{"type": "text", "text": "Visible answer line"}],
                    "timestamp": "2026-04-12T00:00:01",
                },
            )
        )
        await db_session.commit()

        service = SessionService(db_session)
        sessions = await service.list_sessions("alice")

    assert len(sessions) == 1
    assert sessions[0].preview == "Visible answer line"

    await engine.dispose()


@pytest.mark.asyncio
async def test_delete_session_removes_chat_session_and_agentscope_history() -> None:
    import importlib
    from sqlalchemy import select

    sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
    message_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.MessageTable
    session_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.SessionTable
    user_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.UserTable

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(sqlalchemy_memory.Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Inbox"))
        db_session.add(user_table(id="alice"))
        db_session.add(session_table(id="session-1", user_id="alice"))
        db_session.add(
            message_table(
                id="assistant-row-1",
                session_id="session-1",
                index=1,
                msg={
                    "id": "assistant-1",
                    "role": "assistant",
                    "content": "hello",
                    "timestamp": "2026-04-12T00:00:01",
                },
            )
        )
        await db_session.commit()

        service = SessionService(db_session)
        deleted = await service.delete_session("alice", "session-1")
        remaining_chat_session = await db_session.get(ChatSession, "session-1")
        remaining_agentscope_session = await db_session.execute(
            select(session_table).where(session_table.id == "session-1")
        )
        remaining_agentscope_messages = await db_session.execute(
            select(message_table).where(message_table.session_id == "session-1")
        )

    assert deleted is True
    assert remaining_chat_session is None
    assert remaining_agentscope_session.scalar_one_or_none() is None
    assert remaining_agentscope_messages.scalar_one_or_none() is None

    await engine.dispose()


@pytest.mark.asyncio
async def test_list_messages_includes_failed_assistant_turn_state() -> None:
    import importlib

    sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
    session_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.SessionTable
    user_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.UserTable

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(sqlalchemy_memory.Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Inbox"))
        db_session.add(user_table(id="alice"))
        db_session.add(session_table(id="session-1", user_id="alice"))
        db_session.add(
            ChatTurnState(
                id="turn-state-1",
                session_id="session-1",
                user_id="alice",
                assistant_message_id="assistant-failed-1",
                status="failed",
                content="partial answer",
                error="provider failed",
            )
        )
        await db_session.commit()

        service = SessionService(db_session)
        messages = await service.list_messages("alice", "session-1")

    assert len(messages) == 1
    assert messages[0].id == "assistant-failed-1"
    assert messages[0].role == "assistant"
    assert messages[0].content == "partial answer"
    assert messages[0].status == "failed"
    assert messages[0].error == "provider failed"

    await engine.dispose()


@pytest.mark.asyncio
async def test_list_messages_merges_turn_state_metadata_onto_persisted_assistant_message() -> None:
    import importlib

    sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
    message_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.MessageTable
    session_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.SessionTable
    user_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.UserTable

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(sqlalchemy_memory.Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Inbox"))
        db_session.add(user_table(id="alice"))
        db_session.add(session_table(id="session-1", user_id="alice"))
        db_session.add(
            message_table(
                id="assistant-row-1",
                session_id="session-1",
                index=1,
                msg={
                    "id": "assistant-1",
                    "role": "assistant",
                    "content": [{"type": "text", "text": "partial answer"}],
                    "timestamp": "2026-04-12T00:00:01",
                },
            )
        )
        db_session.add(
            ChatTurnState(
                id="turn-state-1",
                session_id="session-1",
                user_id="alice",
                assistant_message_id="assistant-1",
                status="failed",
                content="partial answer",
                error="provider failed",
            )
        )
        await db_session.commit()

        service = SessionService(db_session)
        messages = await service.list_messages("alice", "session-1")

    assert len(messages) == 1
    assert messages[0].id == "assistant-1"
    assert messages[0].role == "assistant"
    assert messages[0].content == "partial answer"
    assert messages[0].status == "failed"
    assert messages[0].error == "provider failed"

    await engine.dispose()


def test_build_async_db_url_rejects_unsupported_driver() -> None:
    with pytest.raises(ValueError, match="unsupported async database URL"):
        _build_async_db_url("sqlite:///tmp/agents.db")


def test_get_postgres_db_fails_immediately_for_legacy_use() -> None:
    with pytest.raises(RuntimeError, match="temporary compatibility shim"):
        get_postgres_db()


@pytest.mark.asyncio
async def test_list_messages_normalizes_mixed_naive_and_aware_timestamps_before_sorting(monkeypatch: pytest.MonkeyPatch) -> None:
    import importlib

    sqlalchemy_memory = importlib.import_module('agentscope.memory._working_memory._sqlalchemy_memory')

    class FakeResult:
        def __init__(self, *, rows: list[object] | None = None, scalar: object | None = None) -> None:
            self._rows = rows or []
            self._scalar = scalar

        def all(self) -> list[object]:
            return self._rows

        def scalar_one_or_none(self) -> object | None:
            return self._scalar

    session = SimpleNamespace(
        created_at=datetime(2026, 4, 12, 0, 0, 0, tzinfo=timezone.utc),
    )
    aware_turn_created_at = datetime(2026, 4, 12, 0, 0, 2, tzinfo=timezone.utc)

    results = iter(
        [
            FakeResult(scalar=session),
            FakeResult(rows=[]),
            FakeResult(
                rows=[
                    ('assistant-running-1', 'running', 'streaming reply', None, aware_turn_created_at),
                ]
            ),
            FakeResult(
                rows=[
                    (
                        'user-row-1',
                        {
                            'id': 'user-1',
                            'role': 'user',
                            'content': 'hello',
                            'timestamp': '2026-04-12T00:00:01',
                        },
                        1,
                    ),
                ]
            ),
        ]
    )

    class FakeAsyncSession:
        async def execute(self, _statement: object) -> FakeResult:
            return next(results)

    service = SessionService(FakeAsyncSession())
    messages = await service.list_messages('alice', 'session-1')

    assert [message.id for message in messages] == ['user-1', 'assistant-running-1']
    assert all(message.created_at.tzinfo is not None for message in messages)
    assert messages[0].created_at == datetime(2026, 4, 12, 0, 0, 1, tzinfo=timezone.utc)
    assert messages[1].created_at == aware_turn_created_at


@pytest.mark.asyncio
async def test_list_sessions_uses_latest_turn_state_preview_for_multi_turn_session() -> None:
    import importlib

    sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
    session_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.SessionTable
    user_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.UserTable

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(sqlalchemy_memory.Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Inbox"))
        db_session.add(user_table(id="alice"))
        db_session.add(session_table(id="session-1", user_id="alice"))
        db_session.add(
            ChatTurnState(
                id="turn-state-1",
                session_id="session-1",
                user_id="alice",
                assistant_message_id="assistant-1",
                status="finished",
                content="Older reply",
                created_at=datetime(2026, 4, 12, 0, 0, 1, tzinfo=timezone.utc),
            )
        )
        db_session.add(
            ChatTurnState(
                id="turn-state-2",
                session_id="session-1",
                user_id="alice",
                assistant_message_id="assistant-2",
                status="running",
                content="Latest streamed reply",
                created_at=datetime(2026, 4, 12, 0, 0, 2, tzinfo=timezone.utc),
            )
        )
        await db_session.commit()

        service = SessionService(db_session)
        sessions = await service.list_sessions("alice")

    assert len(sessions) == 1
    assert sessions[0].preview == "Latest streamed reply"
    assert sessions[0].status == "running"

    await engine.dispose()
