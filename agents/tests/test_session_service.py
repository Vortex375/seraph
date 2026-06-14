from datetime import datetime, timezone

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from agentscope.message import Msg, TextBlock
from agentscope.state import AgentState
from chat.session_service import SessionService
from documents.models import Base, ChatSession, ChatTurnState


def _build_state_with_messages(*messages: tuple[str, str]) -> dict:
    """Build a serialized AgentState with user/assistant text messages.

    Each tuple is (role, text).
    """
    context = [Msg(name=role, role=role, content=[TextBlock(text=text)]) for role, text in messages]
    return AgentState(context=context).model_dump(mode="json")


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
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Roadmap Review"))
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
async def test_delete_session_removes_chat_session_and_turn_state() -> None:
    from sqlalchemy import select

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Inbox"))
        db_session.add(
            ChatTurnState(
                id="turn-state-1",
                session_id="session-1",
                user_id="alice",
                assistant_message_id="assistant-1",
                status="finished",
                content="hello",
            )
        )
        await db_session.commit()

        service = SessionService(db_session)
        deleted = await service.delete_session("alice", "session-1")
        remaining_chat_session = await db_session.get(ChatSession, "session-1")
        remaining_turn_state = await db_session.execute(
            select(ChatTurnState).where(ChatTurnState.session_id == "session-1")
        )

    assert deleted is True
    assert remaining_chat_session is None
    assert remaining_turn_state.scalar_one_or_none() is None

    await engine.dispose()


@pytest.mark.asyncio
async def test_list_messages_includes_failed_assistant_turn_state() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Inbox"))
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
async def test_list_messages_reads_user_and_assistant_messages_from_agent_state() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        state = _build_state_with_messages(
            ("user", "hello"),
            ("assistant", "Hi there!"),
        )
        db_session.add(
            ChatSession(
                id="session-1",
                user_id="alice",
                title="Inbox",
                agent_state=state,
            )
        )
        await db_session.commit()

        service = SessionService(db_session)
        messages = await service.list_messages("alice", "session-1")

    assert len(messages) == 2
    assert messages[0].role == "user"
    assert messages[0].content == "hello"
    assert messages[1].role == "assistant"
    assert messages[1].content == "Hi there!"

    await engine.dispose()


@pytest.mark.asyncio
async def test_list_sessions_uses_latest_turn_state_preview_for_multi_turn_session() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        db_session.add(ChatSession(id="session-1", user_id="alice", title="Inbox"))
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
