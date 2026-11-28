from __future__ import annotations

import asyncio
import logging
from collections.abc import AsyncIterator
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from fastapi.responses import StreamingResponse
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from api.models import ChatMessageResponse, MessageCreateRequest, SessionCreateRequest, SessionResponse
from auth.current_user import AuthenticatedUser, get_current_user
from chat.agent_factory import AgentFactory
from chat.session_service import SessionService
from chat.turns import TurnEvent, run_turn
from db.session import get_db_session, get_session_factory

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/v1/chat", tags=["chat"])


def get_agent_factory(request: Request) -> AgentFactory:
    factory: AgentFactory = request.app.state.agent_factory
    return factory


CurrentUser = Annotated[AuthenticatedUser, Depends(get_current_user)]
Db = Annotated[AsyncSession, Depends(get_db_session)]

# Turns run as tasks detached from the request, so a reply finishes and is saved even if the client goes away.
# Holding a reference keeps a running task from being garbage-collected.
_running_turns: set[asyncio.Task[None]] = set()


async def _require_session(db: AsyncSession, user_id: str, session_id: str) -> None:
    if await SessionService(db).get_session(user_id, session_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="chat session not found")


@router.get("/sessions", response_model=list[SessionResponse])
async def list_sessions(user: CurrentUser, db: Db) -> list[SessionResponse]:
    sessions = await SessionService(db).list_sessions(user.user_id)
    return [SessionResponse.model_validate(session) for session in sessions]


@router.post("/sessions", response_model=SessionResponse, status_code=status.HTTP_201_CREATED)
async def create_session(payload: SessionCreateRequest, user: CurrentUser, db: Db) -> SessionResponse:
    return SessionResponse.model_validate(await SessionService(db).create_session(user.user_id, payload.title))


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_session(session_id: str, user: CurrentUser, db: Db) -> Response:
    if not await SessionService(db).delete_session(user.user_id, session_id):
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="chat session not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/sessions/{session_id}/messages", response_model=list[ChatMessageResponse])
async def list_messages(session_id: str, user: CurrentUser, db: Db) -> list[ChatMessageResponse]:
    await _require_session(db, user.user_id, session_id)
    messages = await SessionService(db).list_messages(user.user_id, session_id)
    return [ChatMessageResponse.model_validate(message) for message in messages]


@router.post("/sessions/{session_id}/messages/stream")
async def create_message_and_stream(
    session_id: str,
    payload: MessageCreateRequest,
    user: CurrentUser,
    db: Db,
    factory: Annotated[AgentFactory, Depends(get_agent_factory)],
    session_factory: Annotated[async_sessionmaker[AsyncSession], Depends(get_session_factory)],
) -> StreamingResponse:
    await _require_session(db, user.user_id, session_id)
    queue: asyncio.Queue[TurnEvent | None] = asyncio.Queue()
    task = asyncio.create_task(
        _publish_turn(
            queue, session_factory, factory, session_id=session_id, user_id=user.user_id, message=payload.message
        )
    )
    _running_turns.add(task)
    task.add_done_callback(_running_turns.discard)
    return StreamingResponse(_sse(queue), media_type="text/event-stream")


async def _publish_turn(
    queue: asyncio.Queue[TurnEvent | None],
    session_factory: async_sessionmaker[AsyncSession],
    factory: AgentFactory,
    *,
    session_id: str,
    user_id: str,
    message: str,
) -> None:
    try:
        async with session_factory() as db:
            async for event in run_turn(db, factory, session_id=session_id, user_id=user_id, message=message):
                await queue.put(event)
    except Exception:
        logger.exception("chat turn for session %s failed", session_id)
    finally:
        await queue.put(None)


async def _sse(queue: asyncio.Queue[TurnEvent | None]) -> AsyncIterator[str]:
    while (event := await queue.get()) is not None:
        yield event.sse()
