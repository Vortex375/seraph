from collections.abc import AsyncIterator, Callable
from typing import Any

import pytest
from pydantic_ai import ModelAuthenticationError, ModelMessage, ModelResponse, TextPart, ToolReturnPart, UserPromptPart
from pydantic_ai.models.function import AgentInfo, DeltaToolCall
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from chat.agent_factory import AgentFactory, load_history
from chat.session_service import SessionService
from chat.turns import MISSING_CREDENTIALS_MESSAGE, TurnEvent, run_turn
from documents.models import ChatSession, ChatTurnFailure, ChatTurnSource, ChatTurnState
from tests.support import SPEC_CITATION, search_then_answer


async def _seed_session(
    session_factory: async_sessionmaker[AsyncSession], user_id: str = "alice", title: str = "Inbox"
) -> None:
    async with session_factory() as db:
        db.add(ChatSession(id="session-1", user_id=user_id, title=title))
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
    assert chat_session is not None
    history = load_history(chat_session.agent_state)
    assert history is not None and {m.run_id for m in history} == {turn_id}


@pytest.mark.asyncio
async def test_each_turn_sends_history_and_the_current_time(
    session_factory: async_sessionmaker[AsyncSession],
    make_factory: Callable[..., AgentFactory],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    clock = iter(["Current date/time: 2026-11-28T09:00+01:00", "Current date/time: 2026-12-03T18:30+01:00"])
    monkeypatch.setattr("chat.agent_factory.current_datetime", lambda: next(clock))
    seen: list[tuple[list[str], str]] = []

    async def record(messages: list[ModelMessage], info: AgentInfo) -> AsyncIterator[str]:
        seen.append(
            (
                [str(p.content) for m in messages for p in m.parts if isinstance(p, UserPromptPart)],
                info.instructions or "",
            )
        )
        yield "ok"

    await _seed_session(session_factory)
    factory = make_factory(record)

    await _run(session_factory, factory, "first")
    await _run(session_factory, factory, "second")

    (first_prompts, first_instructions), (second_prompts, second_instructions) = seen
    assert first_prompts == ["first"] and "2026-11-28T09:00" in first_instructions
    assert second_instructions == first_instructions, "the cached prefix is not rewritten when the time changes"
    assert second_prompts[:2] == ["first", "second"] and "2026-12-03T18:30" in second_prompts[2]
    async with session_factory() as db:
        listed = await SessionService(db).list_messages("alice", "session-1")
    assert [(m.role, m.content) for m in listed] == [
        ("user", "first"),
        ("assistant", "ok"),
        ("user", "second"),
        ("assistant", "ok"),
    ]


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


async def _title(session_factory: async_sessionmaker[AsyncSession]) -> str:
    async with session_factory() as db:
        chat_session = await db.get(ChatSession, "session-1")
    assert chat_session is not None
    return chat_session.title


@pytest.mark.asyncio
async def test_first_turn_names_a_placeholder_titled_session_once(
    session_factory: async_sessionmaker[AsyncSession], make_factory: Callable[..., AgentFactory]
) -> None:
    title_requests: list[list[str]] = []

    def name_it(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        title_requests.append([str(p.content) for m in messages for p in m.parts if isinstance(p, UserPromptPart)])
        return ModelResponse(parts=[TextPart('  "Launch  date question."  ')])

    await _seed_session(session_factory, title="New chat")
    factory = make_factory(search_then_answer, title_function=name_it)

    first = await _run(session_factory, factory, "When is launch?")
    await _run(session_factory, factory, "And the beta?")

    assert first[-1].type == "done"
    assert await _title(session_factory) == "Launch date question"
    assert title_requests == [["When is launch?"]], "only the first turn names the session"


@pytest.mark.asyncio
async def test_title_failure_keeps_the_placeholder_and_the_turn(
    session_factory: async_sessionmaker[AsyncSession], make_factory: Callable[..., AgentFactory]
) -> None:
    def broken(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        raise RuntimeError("title model down")

    await _seed_session(session_factory, title="New conversation")

    events = await _run(session_factory, make_factory(search_then_answer, title_function=broken))

    assert events[-1].type == "done"
    assert await _title(session_factory) == "New conversation"
    async with session_factory() as db:
        assert (await db.scalar(select(ChatTurnState.status))) == "finished"


@pytest.mark.asyncio
async def test_custom_titles_are_never_replaced(
    session_factory: async_sessionmaker[AsyncSession], make_factory: Callable[..., AgentFactory]
) -> None:
    calls: list[object] = []

    def name_it(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        calls.append(messages)
        return ModelResponse(parts=[TextPart("Something else")])

    await _seed_session(session_factory, title="Roadmap Review")

    await _run(session_factory, make_factory(search_then_answer, title_function=name_it))

    assert await _title(session_factory) == "Roadmap Review"
    assert calls == []
