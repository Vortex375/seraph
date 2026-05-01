from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from datetime import datetime, timezone
import json
import contextlib
from typing import Any
from uuid import uuid4

from agentscope.memory import AsyncSQLAlchemyMemory
from agentscope.message import Msg
from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from fastapi.responses import StreamingResponse
from sqlalchemy import select

from api.models import (
    ChatMessageResponse,
    MessageCreateRequest,
    SessionCreateRequest,
    SessionResponse,
)
from auth.current_user import AuthenticatedUser, get_current_user
from chat.citations import record_failure, record_sources, sources_from_knowledge_documents
from chat.file_models import FileCitation
from chat.session_service import SessionService
from chat.streaming import stream_agent_reply
from db.session import SessionLocal, get_db_session
from documents.models import ChatSession, ChatTurnState

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
    return (
        "api key" in normalized
        or "authenticationerror" in normalized
        or "401" in normalized
        or "openai_api_key" in normalized
        or "chat streaming is unavailable until" in normalized
    )


def _stream_setup_error_chunk(*, assistant_message_id: str) -> str:
    payload = {
        "id": assistant_message_id,
        "role": "assistant",
        "type": "error",
        "content": "Chat streaming is unavailable until OPENAI_API_KEY is configured for agents-api.",
    }
    return f"data: {json.dumps(payload)}\n\n"


def _normalize_citations(citations: object) -> list[dict[str, str]]:
    if not isinstance(citations, list):
        return []

    normalized: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for citation in citations:
        if not isinstance(citation, dict):
            continue
        provider_id = citation.get("provider_id")
        path = citation.get("path")
        if not isinstance(provider_id, str) or not provider_id:
            continue
        if not isinstance(path, str) or not path:
            continue
        citation_key = (provider_id, path)
        if citation_key in seen:
            continue
        seen.add(citation_key)
        label = citation.get("label")
        normalized.append(
            FileCitation(
                provider_id=provider_id,
                path=path,
                label=label if isinstance(label, str) and label else path,
            ).to_dict()
        )
    return normalized


def _trusted_turn_citations(*, retrieval_sources: list[dict[str, str]], tool_citations: object) -> list[dict[str, str]]:
    if not isinstance(tool_citations, list):
        tool_citations = []
    return _normalize_citations([*retrieval_sources, *tool_citations])


def _citation_sources(citations: list[dict[str, str]]) -> list[dict[str, str]]:
    return [{"provider_id": citation["provider_id"], "path": citation["path"]} for citation in citations]


def _install_turn_tool_citations(agent: Any) -> tuple[bool, Any] | None:
    had_attr = hasattr(agent, "_seraph_tool_citations")
    original = getattr(agent, "_seraph_tool_citations", None) if had_attr else None
    try:
        setattr(agent, "_seraph_tool_citations", [])
    except Exception:
        return None
    return had_attr, original


def _restore_turn_tool_citations(agent: Any, state: tuple[bool, Any] | None) -> None:
    if state is None:
        return
    had_attr, original = state
    try:
        if had_attr:
            setattr(agent, "_seraph_tool_citations", original)
            return
        delattr(agent, "_seraph_tool_citations")
    except Exception:
        return None


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


async def _upsert_turn_state_with_isolated_session(
    *,
    session_id: str,
    user_id: str,
    assistant_message_id: str,
    status: str,
    content: str,
    error: str | None = None,
) -> None:
    async with SessionLocal() as session:
        result = await session.execute(
            select(ChatTurnState).where(ChatTurnState.assistant_message_id == assistant_message_id)
        )
        state = result.scalar_one_or_none()
        if state is None:
            state = ChatTurnState(
                session_id=session_id,
                user_id=user_id,
                assistant_message_id=assistant_message_id,
                status=status,
                content=content,
                error=error,
            )
            session.add(state)
        else:
            state.status = status
            state.content = content
            state.error = error
        await session.commit()


async def _touch_session_activity(*, session_id: str) -> None:
    async with SessionLocal() as session:
        result = await session.execute(select(ChatSession).where(ChatSession.id == session_id))
        chat_session = result.scalar_one_or_none()
        if chat_session is None:
            return
        now = datetime.now(timezone.utc)
        chat_session.updated_at = now
        chat_session.last_message_at = now
        await session.commit()


async def _persist_user_message(*, db: Any, session_id: str, user_id: str, message: str) -> str:
    msg = Msg("user", message, "user")
    memory = AsyncSQLAlchemyMemory(db, session_id=session_id, user_id=user_id)
    await memory.add(msg, skip_duplicated=False)
    return msg.id


def _extract_text_content(raw_content: object) -> str:
    if isinstance(raw_content, str):
        return raw_content
    if isinstance(raw_content, list):
        return "".join(
            block.get("text", "") for block in raw_content if isinstance(block, dict) and block.get("type") == "text"
        )
    return ""


def _merge_stream_content(*, prior_content: str, payload: dict[str, Any]) -> str:
    next_content = _extract_text_content(payload.get("content"))
    if not next_content:
        return prior_content
    if payload.get("type") == "delta":
        return f"{prior_content}{next_content}"
    return next_content


def _is_error_payload(payload: dict[str, Any]) -> bool:
    return payload.get("type") == "error"


def _payload_message_id(payload: dict[str, Any]) -> str | None:
    payload_message_id = payload.get("id")
    return payload_message_id if isinstance(payload_message_id, str) and payload_message_id else None


async def _run_turn_and_publish(
    *,
    session_id: str,
    user_id: str,
    message: str,
    request: Request,
    queue: asyncio.Queue[str | None],
) -> None:
    agent_factory = request.app.state.agent_factory if hasattr(request, "app") else None
    if agent_factory is None:
        await queue.put(None)
        return

    assistant_message_id: str | None = None
    accumulated_content = ""

    try:
        agent = agent_factory.create(user_id, session_id)
        async for chunk in _stream_chat_events(db=None, session_id=session_id, agent=agent, user_input=message):
            payload = _parse_sse_payload(chunk)
            if payload is not None:
                assistant_message_id = _payload_message_id(payload) or assistant_message_id
                accumulated_content = _merge_stream_content(prior_content=accumulated_content, payload=payload)
                if assistant_message_id is not None:
                    await _upsert_turn_state_with_isolated_session(
                        session_id=session_id,
                        user_id=user_id,
                        assistant_message_id=assistant_message_id,
                        status="running",
                        content=accumulated_content,
                    )
                if _is_error_payload(payload):
                    raise RuntimeError(accumulated_content or "chat streaming failed")
            await queue.put(chunk)

        if assistant_message_id is None:
            assistant_message_id = str(uuid4())
        await _upsert_turn_state_with_isolated_session(
            session_id=session_id,
            user_id=user_id,
            assistant_message_id=assistant_message_id,
            status="finished",
            content=accumulated_content,
            error=None,
        )
        await _touch_session_activity(session_id=session_id)
        await queue.put(f'data: {{"id":"{assistant_message_id}","type":"done"}}\n\n')
    except BaseException as exc:
        if assistant_message_id is None:
            assistant_message_id = str(uuid4())
        await _upsert_turn_state_with_isolated_session(
            session_id=session_id,
            user_id=user_id,
            assistant_message_id=assistant_message_id,
            status="failed",
            content=accumulated_content,
            error=str(exc),
        )
        if not _looks_like_missing_model_credentials(str(exc)) and not getattr(exc, "_seraph_failure_recorded", False):
            await _record_failure_with_isolated_session(
                session_id=session_id,
                assistant_message_id=assistant_message_id,
                error=str(exc),
            )
        with contextlib.suppress(Exception):
            await queue.put(
                f'data: {{"id":"{assistant_message_id}","type":"error","content":{json.dumps(str(exc))}}}\n\n'
            )
    finally:
        await queue.put(None)


async def _stream_message_create(
    *,
    db: Any,
    session_id: str,
    user_id: str,
    message: str,
    request: Request,
) -> AsyncIterator[str]:
    await _persist_user_message(db=db, session_id=session_id, user_id=user_id, message=message)
    await _touch_session_activity(session_id=session_id)
    queue: asyncio.Queue[str | None] = asyncio.Queue()
    asyncio.create_task(
        _run_turn_and_publish(
            session_id=session_id,
            user_id=user_id,
            message=message,
            request=request,
            queue=queue,
        )
    )

    while True:
        chunk = await queue.get()
        if chunk is None:
            break
        yield chunk


async def _stream_chat_events(db: Any, session_id: str, agent: Any, user_input: str) -> AsyncIterator[str]:
    assistant_message_id = str(uuid4())
    tool_citation_state = _install_turn_tool_citations(agent)
    try:
        pending_sources = await _retrieve_turn_sources(agent, user_input)
        persisted_sources_by_message: dict[str, set[tuple[str, str]]] = {}
        del db
        async for chunk in stream_agent_reply(agent=agent, user_input=user_input):
            payload = _parse_sse_payload(chunk)
            if payload is not None:
                trusted_citations = _trusted_turn_citations(
                    retrieval_sources=pending_sources,
                    tool_citations=getattr(agent, "_seraph_tool_citations", []) if tool_citation_state is not None else [],
                )
                trusted_sources = _citation_sources(trusted_citations)
                payload["citations"] = trusted_citations
                payload_message_id = payload.get("id") if isinstance(payload.get("id"), str) else None
                if payload_message_id:
                    assistant_message_id = payload_message_id
                    persisted_sources = persisted_sources_by_message.setdefault(assistant_message_id, set())
                    new_sources = [
                        source
                        for source in trusted_sources
                        if (source["provider_id"], source["path"]) not in persisted_sources
                    ]
                    if new_sources:
                        await _record_sources_with_isolated_session(
                            session_id=session_id,
                            assistant_message_id=assistant_message_id,
                            sources=new_sources,
                        )
                        persisted_sources.update((source["provider_id"], source["path"]) for source in new_sources)
                chunk = f"data: {json.dumps(payload)}\n\n"
            yield chunk
        trusted_citations = _trusted_turn_citations(
            retrieval_sources=pending_sources,
            tool_citations=getattr(agent, "_seraph_tool_citations", []) if tool_citation_state is not None else [],
        )
        trusted_sources = _citation_sources(trusted_citations)
        persisted_sources = persisted_sources_by_message.setdefault(assistant_message_id, set())
        new_sources = [
            source for source in trusted_sources if (source["provider_id"], source["path"]) not in persisted_sources
        ]
        if new_sources:
            await _record_sources_with_isolated_session(
                session_id=session_id,
                assistant_message_id=assistant_message_id,
                sources=new_sources,
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
        setattr(exc, "_seraph_failure_recorded", True)
        raise
    finally:
        _restore_turn_tool_citations(agent, tool_citation_state)


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


@router.post("/sessions/{session_id}/messages/stream")
async def create_message_and_stream(
    session_id: str,
    payload: MessageCreateRequest,
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
    db: Any = Depends(get_db_session),
) -> Response:
    await _get_owned_session(db, user.user_id, session_id)
    return StreamingResponse(
        _stream_message_create(
            db=db,
            session_id=session_id,
            user_id=user.user_id,
            message=payload.message,
            request=request,
        ),
        media_type="text/event-stream",
    )


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
