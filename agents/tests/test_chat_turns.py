from collections.abc import AsyncIterator, Callable
from typing import Any

import pytest
from pydantic_ai import ModelAuthenticationError, ModelMessage, ToolReturnPart, UserPromptPart
from pydantic_ai.models.function import AgentInfo, DeltaToolCall
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from chat.agent_factory import AgentFactory, load_history
from chat.turns import MISSING_CREDENTIALS_MESSAGE, TurnEvent, run_turn
from documents.models import ChatSession, ChatTurnFailure, ChatTurnSource, ChatTurnState
from tests.support import SPEC_CITATION, search_then_answer


async def _seed_session(session_factory: async_sessionmaker[AsyncSession], user_id: str = "alice") -> None:
    async with session_factory() as db:
        db.add(ChatSession(id="session-1", user_id=user_id, title="Inbox"))
        await db.commit()


async def _run(
    session_factory: async_sessionmaker[AsyncSession], factory: AgentFactory, message: str = "When is launch?"
) -> list[TurnEvent]:
    async with session_factory() as db:
        return [e async for e in run_turn(db, factory, session_id="session-1", user_id="alice", message=message)]


@pytest.mark.asyncio
async def test_run_turn_streams_reply_and_persists_turn(
    session_factory: async_sessionmaker[AsyncSession], make_factory: Callable[..., AgentFactory]
) -> None:
    await _seed_session(session_factory)

    events = await _run(session_factory, make_factory(search_then_answer))

    turn_id = events[0].id
    assert [(e.type, e.content) for e in events] == [("delta", "July "), ("delta", "first"), ("done", None)]
    assert {e.id for e in events} == {turn_id}
    assert events[-1].citations == [SPEC_CITATION]
    async with session_factory() as db:
        turn = await db.scalar(select(ChatTurnState))
        sources = (await db.scalars(select(ChatTurnSource))).all()
        chat_session = await db.get(ChatSession, "session-1")
    assert turn is not None and (turn.assistant_message_id, turn.status, turn.content) == (
        turn_id,
        "finished",
        "July first",
    )
    assert [(s.assistant_message_id, s.provider_id, s.path) for s in sources] == [(turn_id, "space-a", "/team/spec.md")]
    assert chat_session is not None and chat_session.system_prompt
    assert "Current date/time:" in chat_session.system_prompt
    history = load_history(chat_session.agent_state)
    assert history is not None and {m.run_id for m in history} == {turn_id}


@pytest.mark.asyncio
async def test_run_turn_sends_saved_history_and_prompt_to_the_model(
    session_factory: async_sessionmaker[AsyncSession], make_factory: Callable[..., AgentFactory]
) -> None:
    seen: list[tuple[list[str], str | None]] = []

    async def record(messages: list[ModelMessage], info: AgentInfo) -> AsyncIterator[str]:
        prompts = [str(p.content) for m in messages for p in m.parts if isinstance(p, UserPromptPart)]
        seen.append((prompts, info.instructions))
        yield "ok"

    await _seed_session(session_factory)
    factory = make_factory(record)

    await _run(session_factory, factory, "first")
    await _run(session_factory, factory, "second")

    assert [prompts for prompts, _ in seen] == [["first"], ["first", "second"]]
    assert seen[0][1] == seen[1][1], "the system prompt is created once and reused"


@pytest.mark.asyncio
async def test_run_turn_records_failure_with_partial_content(
    session_factory: async_sessionmaker[AsyncSession], make_factory: Callable[..., AgentFactory]
) -> None:
    async def fail_midway(messages: list[ModelMessage], info: AgentInfo) -> AsyncIterator[str]:
        del messages, info
        yield "par"
        raise RuntimeError("provider exploded")

    await _seed_session(session_factory)

    events = await _run(session_factory, make_factory(fail_midway))

    assert [(e.type, e.content) for e in events] == [("delta", "par"), ("error", "provider exploded")]
    async with session_factory() as db:
        turn = await db.scalar(select(ChatTurnState))
        failures = (await db.scalars(select(ChatTurnFailure))).all()
        chat_session = await db.get(ChatSession, "session-1")
    assert turn is not None and (turn.status, turn.content, turn.error) == ("failed", "par", "provider exploded")
    assert [f.error for f in failures] == ["provider exploded"]
    assert chat_session is not None and load_history(chat_session.agent_state) is None


@pytest.mark.asyncio
async def test_run_turn_explains_missing_credentials(
    session_factory: async_sessionmaker[AsyncSession], make_factory: Callable[..., AgentFactory]
) -> None:
    async def reject(messages: list[ModelMessage], info: AgentInfo) -> AsyncIterator[str]:
        del messages, info
        raise ModelAuthenticationError("gpt-test", "401 invalid api key")
        yield ""

    await _seed_session(session_factory)

    events = await _run(session_factory, make_factory(reject))

    assert [(e.type, e.content) for e in events] == [("error", MISSING_CREDENTIALS_MESSAGE)]
    async with session_factory() as db:
        failure = await db.scalar(select(ChatTurnFailure))
    assert failure is not None and "invalid api key" in failure.error


@pytest.mark.asyncio
async def test_run_turn_rejects_another_users_session(
    session_factory: async_sessionmaker[AsyncSession], make_factory: Callable[..., AgentFactory]
) -> None:
    await _seed_session(session_factory, user_id="bob")

    events = await _run(session_factory, make_factory(search_then_answer))

    assert [(e.type, e.content) for e in events] == [("error", "chat session not found")]
    async with session_factory() as db:
        assert await db.scalar(select(ChatTurnState)) is None


@pytest.mark.asyncio
async def test_tool_failure_is_reported_to_the_model_not_the_user(
    session_factory: async_sessionmaker[AsyncSession], make_factory: Callable[..., AgentFactory]
) -> None:
    tool_results: list[object] = []
    tool_schemas: list[dict[str, Any]] = []

    async def search_then_explain(messages: list[ModelMessage], info: AgentInfo) -> AsyncIterator[Any]:
        returns = [(p.content, p.outcome) for m in messages for p in m.parts if isinstance(p, ToolReturnPart)]
        if not returns:
            tool_schemas.extend(
                t.parameters_json_schema for t in info.function_tools if t.name == "search_knowledge_base"
            )
            yield {0: DeltaToolCall(name="search_knowledge_base", json_args='{"query": "launch"}')}
            return
        tool_results.extend(returns)
        yield "Search is unavailable."

    class FailingRetrieval:
        async def retrieve(self, query: str, scopes: list[Any], limit: int = 5) -> list[Any]:
            raise RuntimeError("no spaces found")

    await _seed_session(session_factory)
    events = await _run(session_factory, make_factory(search_then_explain, retrieval=FailingRetrieval()))

    assert [(e.type, e.content) for e in events] == [("delta", "Search is unavailable."), ("done", None)]
    assert tool_results == [("no spaces found", "failed")]
    assert tool_schemas[0]["properties"]["query"]["description"] == "Search query in natural language."
