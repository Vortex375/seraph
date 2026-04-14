import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from chat.session_service import SessionService
from db.session import _build_async_db_url, get_postgres_db
from documents.models import Base, ChatSession, PendingChatTurn


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
        db_session.add(PendingChatTurn(id="turn-1", session_id="session-1", user_id="alice", message="still running"))
        await db_session.commit()

        service = SessionService(db_session)
        sessions = await service.list_sessions("alice")

    assert len(sessions) == 1
    assert sessions[0].headline == "Roadmap Review"
    assert sessions[0].preview == "Final preview line"
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


def test_build_async_db_url_rejects_unsupported_driver() -> None:
    with pytest.raises(ValueError, match="unsupported async database URL"):
        _build_async_db_url("sqlite:///tmp/agents.db")


def test_get_postgres_db_fails_immediately_for_legacy_use() -> None:
    with pytest.raises(RuntimeError, match="temporary compatibility shim"):
        get_postgres_db()
