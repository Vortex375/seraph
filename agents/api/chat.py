from __future__ import annotations

from collections.abc import AsyncIterator
from datetime import datetime, timezone
import json
from typing import Any
from uuid import uuid4

from agentscope.message import Msg
from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from fastapi.responses import StreamingResponse
from sqlalchemy import Select, delete, select, update

from api.models import (
    AcceptedMessageResponse,
    ChatMessageResponse,
    MessageCreateRequest,
    SessionCreateRequest,
    SessionResponse,
)
from auth.current_user import AuthenticatedUser, get_current_user
from chat.citations import record_failure, record_sources, sources_from_knowledge_documents
from chat.session_service import DEFAULT_SESSION_TITLE, SessionService, SessionTitleSummarizer, summarize_session_title
from chat.streaming import stream_agent_reply
from db.session import SessionLocal, get_db_session
from documents.models import ChatSession, PendingChatTurn

router = APIRouter(prefix="/api/v1/chat", tags=["chat"])


def _session_response_payload(session: Any) -> dict[str, Any]:
    title = getattr(session, "title")
    return {
        "id": getattr(session, "id"),
        "user_id": getattr(session, "user_id"),
        "title": title,
        "headline": getattr(session, "headline", title),
        "preview": getattr(session, "preview", ""),
        "status": getattr(session, "status", "finished"),
        "created_at": getattr(session, "created_at"),
        "updated_at": getattr(session, "updated_at"),
        "last_message_at": getattr(session, "last_message_at"),
    }


async def _get_owned_session(db: Any, user_id: str, session_id: str) -> Any:
    service = SessionService(db)
    get_session = getattr(service, "get_session", None)
    if get_session is not None:
        session = await get_session(user_id, session_id)
        if session is not None:
            return session
    sessions = await service.list_sessions(user_id)
    for session in sessions:
        if session.id == session_id:
            return session
    raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="chat session not found")


def _parse_sse_payload(chunk: str) -> dict[str, Any] | None:
    if not chunk.startswith("data:"):
        return None

    payload_text = chunk.removeprefix("data:").strip()
    if not payload_text or payload_text == "[DONE]":
        return None

    try:
        payload = json.loads(payload_text)
    except json.JSONDecodeError:
        return None

    return payload if isinstance(payload, dict) else None


def _assistant_message_id_from_error(error: str) -> str | None:
    marker = "assistant id="
    if marker not in error:
        return None
    suffix = error.split(marker, 1)[1].strip()
    return suffix.split()[0] if suffix else None


def _looks_like_missing_model_credentials(error: str) -> bool:
    normalized = error.lower()
    return "api key" in normalized or "authenticationerror" in normalized or "401" in normalized


def _stream_setup_error_chunk(*, assistant_message_id: str) -> str:
    payload = {
        "id": assistant_message_id,
        "role": "assistant",
        "type": "error",
        "content": "Chat streaming is unavailable until OPENAI_API_KEY is configured for agents-api.",
    }
    return f"data: {json.dumps(payload)}\n\n"


async def _retrieve_turn_sources(agent: Any, user_input: str) -> list[dict[str, str]]:
    knowledge_bases = getattr(agent, "knowledge", None)
    if not isinstance(knowledge_bases, list) or not knowledge_bases:
        return []

    knowledge_docs: list[Any] = []
    for knowledge_base in knowledge_bases:
        retrieve = getattr(knowledge_base, "retrieve", None)
        if not callable(retrieve):
            continue
        knowledge_docs.extend(await retrieve(query=user_input, limit=5))
    return sources_from_knowledge_documents(knowledge_docs)


async def _accept_pending_turn(
    *,
    db: Any,
    session_id: str,
    user_id: str,
    message: str,
    title_summarizer: SessionTitleSummarizer | None = None,
) -> PendingChatTurn:
    pending_turn = PendingChatTurn(id=str(uuid4()), session_id=session_id, user_id=user_id, message=message)
    now = datetime.now(timezone.utc)
    db.add(pending_turn)
    get_session = getattr(db, "get", None)
    rollback = getattr(db, "rollback", None)
    try:
        session = await get_session(ChatSession, session_id) if callable(get_session) else None
        title = None
        if session is not None and session.title == DEFAULT_SESSION_TITLE:
            try:
                title = await title_summarizer.summarize(message) if title_summarizer is not None else None
            except Exception:
                title = None
            title = title or summarize_session_title(message)
        update_values: dict[str, Any] = {"last_message_at": now, "updated_at": now}
        if title is not None:
            update_values["title"] = title
        await db.execute(update(ChatSession).where(ChatSession.id == session_id).values(**update_values))
        await db.commit()
    except BaseException:
        if callable(rollback):
            await rollback()
        raise
    await db.refresh(pending_turn)
    return pending_turn


async def _lock_chat_session(*, db: Any, session_id: str, user_id: str, skip_locked: bool) -> bool:
    session_lock_query: Select[tuple[str]] = (
        select(ChatSession.id)
        .where(ChatSession.id == session_id, ChatSession.user_id == user_id)
        .with_for_update(skip_locked=skip_locked)
    )
    locked_session = await db.execute(session_lock_query)
    return locked_session.first() is not None


async def _claim_pending_turn(*, db: Any, session_id: str, user_id: str) -> PendingChatTurn:
    claimed_at = datetime.now(timezone.utc)
    try:
        if not await _lock_chat_session(db=db, session_id=session_id, user_id=user_id, skip_locked=True):
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="no pending chat turn")

        existing_claim_query: Select[tuple[str]] = (
            select(PendingChatTurn.id)
            .where(
                PendingChatTurn.session_id == session_id,
                PendingChatTurn.user_id == user_id,
                PendingChatTurn.claimed.is_(True),
            )
            .limit(1)
            .with_for_update(skip_locked=True)
        )
        existing_claim = await db.execute(existing_claim_query)
        if existing_claim.first() is not None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="no pending chat turn")

        claim_query: Select[tuple[str, str]] = (
            select(PendingChatTurn.id, PendingChatTurn.message)
            .where(
                PendingChatTurn.session_id == session_id,
                PendingChatTurn.user_id == user_id,
                PendingChatTurn.claimed.is_(False),
            )
            .order_by(PendingChatTurn.created_at.asc())
            .limit(1)
            .with_for_update(skip_locked=True)
        )
        selected = await db.execute(claim_query)
        row = selected.first()
        if row is None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="no pending chat turn")

        result = await db.execute(
            update(PendingChatTurn)
            .where(PendingChatTurn.id == row[0], PendingChatTurn.claimed.is_(False))
            .values(claimed=True, claimed_at=claimed_at)
            .returning(PendingChatTurn.id, PendingChatTurn.message)
        )
        claimed_row = result.first()
        if claimed_row is None:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="no pending chat turn")

        await db.commit()
    except BaseException:
        await db.rollback()
        raise

    pending_turn = PendingChatTurn(
        id=claimed_row[0], session_id=session_id, user_id=user_id, message=claimed_row[1], claimed=True
    )
    pending_turn.claimed_at = claimed_at
    return pending_turn


async def _stream_pending_turn(
    *, db: Any, session_id: str, agent: Any, pending_turn: PendingChatTurn
) -> AsyncIterator[str]:
    started_stream = False
    try:
        async for chunk in _stream_chat_events(
            db=db,
            session_id=session_id,
            agent=agent,
            user_input=pending_turn.message,
        ):
            started_stream = True
            yield chunk
    except BaseException:
        if not started_stream:
            await _unclaim_pending_turn(db=db, pending_turn=pending_turn)
        else:
            await _consume_pending_turn(db=db, pending_turn=pending_turn)
        raise
    else:
        if not started_stream:
            await _unclaim_pending_turn(db=db, pending_turn=pending_turn)
            return
        await _consume_pending_turn(db=db, pending_turn=pending_turn)


async def _stream_with_prefetched_chunk(*, first_chunk: str, event_stream: Any) -> AsyncIterator[str]:
    try:
        yield first_chunk
        async for chunk in event_stream:
            yield chunk
    finally:
        close_stream = getattr(event_stream, "aclose", None)
        if callable(close_stream):
            await close_stream()


async def _consume_pending_turn(*, db: Any, pending_turn: PendingChatTurn) -> None:
    try:
        await _lock_chat_session(
            db=db,
            session_id=pending_turn.session_id,
            user_id=pending_turn.user_id,
            skip_locked=False,
        )
        await db.execute(delete(PendingChatTurn).where(PendingChatTurn.id == pending_turn.id))
        await db.commit()
    except BaseException:
        await db.rollback()
        raise


async def _unclaim_pending_turn(*, db: Any, pending_turn: PendingChatTurn) -> None:
    try:
        await _lock_chat_session(
            db=db,
            session_id=pending_turn.session_id,
            user_id=pending_turn.user_id,
            skip_locked=False,
        )
        await db.execute(
            update(PendingChatTurn).where(PendingChatTurn.id == pending_turn.id).values(claimed=False, claimed_at=None)
        )
        await db.commit()
    except BaseException:
        await db.rollback()
        raise


async def _record_sources_with_isolated_session(
    *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
) -> None:
    async with SessionLocal() as session:
        await record_sources(
            session,
            session_id=session_id,
            assistant_message_id=assistant_message_id,
            sources=sources,
        )


async def _record_failure_with_isolated_session(*, session_id: str, assistant_message_id: str, error: str) -> None:
    async with SessionLocal() as session:
        await record_failure(
            session,
            session_id=session_id,
            assistant_message_id=assistant_message_id,
            error=error,
        )


async def _stream_chat_events(db: Any, session_id: str, agent: Any, user_input: str) -> AsyncIterator[str]:
    assistant_message_id = str(uuid4())
    try:
        pending_sources = await _retrieve_turn_sources(agent, user_input)
        del db
        async for chunk in stream_agent_reply(agent=agent, user_input=user_input):
            payload = _parse_sse_payload(chunk)
            if payload is not None:
                payload_message_id = payload.get("id") if isinstance(payload.get("id"), str) else None
                if payload_message_id:
                    assistant_message_id = payload_message_id
                    if pending_sources:
                        await _record_sources_with_isolated_session(
                            session_id=session_id,
                            assistant_message_id=assistant_message_id,
                            sources=pending_sources,
                        )
                        pending_sources = []
            yield chunk
        if pending_sources:
            await _record_sources_with_isolated_session(
                session_id=session_id,
                assistant_message_id=assistant_message_id,
                sources=pending_sources,
            )
    except Exception as exc:
        parsed_assistant_message_id = _assistant_message_id_from_error(str(exc))
        if parsed_assistant_message_id:
            assistant_message_id = parsed_assistant_message_id
        await _record_failure_with_isolated_session(
            session_id=session_id,
            assistant_message_id=assistant_message_id,
            error=str(exc),
        )
        if _looks_like_missing_model_credentials(str(exc)):
            yield _stream_setup_error_chunk(assistant_message_id=assistant_message_id)
            return
        raise


@router.get("/sessions", response_model=list[SessionResponse])
async def list_sessions(
    user: AuthenticatedUser = Depends(get_current_user),
    db: Any = Depends(get_db_session),
) -> list[SessionResponse]:
    service = SessionService(db)
    sessions = await service.list_sessions(user.user_id)
    return [SessionResponse.model_validate(_session_response_payload(session)) for session in sessions]


@router.post("/sessions", response_model=SessionResponse, status_code=status.HTTP_201_CREATED)
async def create_session(
    payload: SessionCreateRequest,
    user: AuthenticatedUser = Depends(get_current_user),
    db: Any = Depends(get_db_session),
) -> SessionResponse:
    service = SessionService(db)
    session = await service.create_session(user.user_id, payload.title)
    return SessionResponse.model_validate(_session_response_payload(session))


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_session(
    session_id: str,
    user: AuthenticatedUser = Depends(get_current_user),
    db: Any = Depends(get_db_session),
) -> Response:
    service = SessionService(db)
    deleted = await service.delete_session(user.user_id, session_id)
    if not deleted:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="chat session not found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/sessions/{session_id}/messages", response_model=AcceptedMessageResponse, status_code=status.HTTP_202_ACCEPTED
)
async def create_message(
    session_id: str,
    payload: MessageCreateRequest,
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
    db: Any = Depends(get_db_session),
) -> AcceptedMessageResponse:
    await _get_owned_session(db, user.user_id, session_id)
    title_summarizer = getattr(request.app.state, "session_title_summarizer", None)
    await _accept_pending_turn(
        db=db,
        session_id=session_id,
        user_id=user.user_id,
        message=payload.message,
        title_summarizer=title_summarizer,
    )
    return AcceptedMessageResponse(accepted=True)


@router.get("/sessions/{session_id}/messages", response_model=list[ChatMessageResponse])
async def list_messages(
    session_id: str,
    user: AuthenticatedUser = Depends(get_current_user),
    db: Any = Depends(get_db_session),
) -> list[ChatMessageResponse]:
    service = SessionService(db)
    messages = await service.list_messages(user.user_id, session_id)
    if not messages and await service.get_session(user.user_id, session_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="chat session not found")
    return [ChatMessageResponse.model_validate(message) for message in messages]


@router.get("/sessions/{session_id}/stream")
async def stream_message(
    request: Request,
    session_id: str,
    user: AuthenticatedUser = Depends(get_current_user),
    db: Any = Depends(get_db_session),
) -> Response:
    await _get_owned_session(db, user.user_id, session_id)

    agent_factory = request.app.state.agent_factory
    pending_turn = await _claim_pending_turn(db=db, session_id=session_id, user_id=user.user_id)
    try:
        agent = agent_factory.create(user.user_id, session_id)
    except BaseException:
        await _unclaim_pending_turn(db=db, pending_turn=pending_turn)
        raise

    event_stream = _stream_pending_turn(db=db, session_id=session_id, agent=agent, pending_turn=pending_turn)
    try:
        first_chunk = await event_stream.__anext__()
    except StopAsyncIteration as exc:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="chat stream produced no events",
        ) from exc

    return StreamingResponse(
        _stream_with_prefetched_chunk(first_chunk=first_chunk, event_stream=event_stream),
        media_type="text/event-stream",
    )
