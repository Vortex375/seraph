from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Literal
from uuid import uuid4

from pydantic_ai import ModelAuthenticationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from chat.agent_factory import AgentFactory, dump_history, load_history
from chat.session_service import PLACEHOLDER_TITLES
from documents.models import ChatSession, ChatTurnFailure, ChatTurnSource, ChatTurnState


logger = logging.getLogger(__name__)

MISSING_CREDENTIALS_MESSAGE = "Chat streaming is unavailable until OPENAI_API_KEY is configured for agents-api."


@dataclass(frozen=True)
class TurnEvent:
    """One step of a running turn; ``citations`` is the turn's cumulative, de-duplicated list."""

    type: Literal["delta", "done", "error"]
    id: str
    content: str | None = None
    citations: list[dict[str, str]] = field(default_factory=list)

    def sse(self) -> str:
        payload: dict[str, object] = {"id": self.id, "role": "assistant", "type": self.type}
        if self.content is not None:
            payload["content"] = self.content
        payload["citations"] = self.citations
        return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


async def run_turn(
    db: AsyncSession, factory: AgentFactory, *, session_id: str, user_id: str, message: str
) -> AsyncIterator[TurnEvent]:
    """Run one chat turn and persist it as it streams.

    Progress is committed after every delta, so the session list and history show the turn even if the client
    disconnects. The assistant message id is the Pydantic AI ``run_id``, which links the saved history to the
    ``ChatTurnState`` and ``ChatTurnSource`` rows. After a session's first successful turn, the session is named
    (see ``_title_new_session``); the ``done`` event is sent before that, so naming never delays the reply.
    """
    turn_id = str(uuid4())
    content = ""
    citations: list[dict[str, str]] = []
    chat_session = await db.get(ChatSession, session_id)
    if chat_session is None or chat_session.user_id != user_id:
        yield TurnEvent("error", turn_id, "chat session not found")
        return
    history = load_history(chat_session.agent_state) or []
    finished = False
    try:
        turn = ChatTurnState(session_id=session_id, user_id=user_id, assistant_message_id=turn_id, content="")
        db.add(turn)
        _touch(chat_session)
        await db.commit()

        agent = factory.create(user_id, history)
        async for delta in agent.stream(message, run_id=turn_id):
            content += delta
            turn.content = content
            _add_new_citations(db, session_id, turn_id, citations, agent.deps.citations)
            await db.commit()
            yield TurnEvent("delta", turn_id, delta, list(citations))

        _add_new_citations(db, session_id, turn_id, citations, agent.deps.citations)
        turn.status = "finished"
        chat_session.agent_state = dump_history(agent.history)
        _touch(chat_session)
        await db.commit()
        finished = True
        yield TurnEvent("done", turn_id, citations=list(citations))
    except asyncio.CancelledError:
        await _record_failure(db, session_id, user_id, turn_id, content, error="turn cancelled")
        raise
    except Exception as exc:
        error = MISSING_CREDENTIALS_MESSAGE if isinstance(exc, ModelAuthenticationError) else str(exc)
        await _record_failure(db, session_id, user_id, turn_id, content, error=error, cause=str(exc))
        yield TurnEvent("error", turn_id, error, list(citations))

    if finished and not history:
        await _title_new_session(db, factory, chat_session, message)


async def _title_new_session(db: AsyncSession, factory: AgentFactory, chat_session: ChatSession, message: str) -> None:
    """Replace a placeholder title with one generated from the first message; on failure the placeholder stays."""
    if chat_session.title.strip().lower() not in PLACEHOLDER_TITLES:
        return
    try:
        title = _clean_title(await factory.title(message))
    except Exception:
        logger.warning("could not title chat session %s", chat_session.id, exc_info=True)
        return
    if title:
        chat_session.title = title
        await db.commit()


def _clean_title(raw: str) -> str:
    title = " ".join(raw.split()).strip("\"'`“”‘’*#").rstrip(".!?:;,").strip()
    return title[:80].rstrip()


def _touch(chat_session: ChatSession) -> None:
    chat_session.updated_at = chat_session.last_message_at = datetime.now(timezone.utc)


def _add_new_citations(
    db: AsyncSession,
    session_id: str,
    turn_id: str,
    citations: list[dict[str, str]],
    candidates: list[dict[str, str]],
) -> None:
    known = {(citation["provider_id"], citation["path"]) for citation in citations}
    for candidate in candidates:
        key = (candidate["provider_id"], candidate["path"])
        if key in known:
            continue
        known.add(key)
        citations.append(candidate)
        db.add(ChatTurnSource(session_id=session_id, assistant_message_id=turn_id, provider_id=key[0], path=key[1]))


async def _record_failure(
    db: AsyncSession,
    session_id: str,
    user_id: str,
    turn_id: str,
    content: str,
    *,
    error: str,
    cause: str | None = None,
) -> None:
    """Mark the turn failed (creating its row if it never got one) and log the underlying cause."""
    await db.rollback()
    turn = await db.scalar(select(ChatTurnState).where(ChatTurnState.assistant_message_id == turn_id))
    if turn is None:
        turn = ChatTurnState(session_id=session_id, user_id=user_id, assistant_message_id=turn_id)
        db.add(turn)
    turn.status = "failed"
    turn.content = content
    turn.error = error
    db.add(ChatTurnFailure(session_id=session_id, assistant_message_id=turn_id, error=cause or error))
    await db.commit()
