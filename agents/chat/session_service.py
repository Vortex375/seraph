from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

from pydantic_ai import ModelMessage, ModelRequest, TextPart, UserPromptPart
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from chat.agent_factory import load_history
from chat.file_models import FileCitation
from documents.models import ChatSession, ChatTurnFailure, ChatTurnSource, ChatTurnState


@dataclass(frozen=True)
class ChatHistoryMessage:
    id: str
    role: str
    content: str
    created_at: datetime
    citations: list[dict[str, str]]
    status: str = "finished"
    error: str | None = None


@dataclass(frozen=True)
class ChatSessionSummary:
    id: str
    user_id: str
    title: str
    headline: str
    preview: str
    status: str
    created_at: datetime
    updated_at: datetime
    last_message_at: datetime


DEFAULT_SESSION_TITLE = "New conversation"


def _message_text_preview(content: object) -> str:
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = "".join(
            block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text"
        )
    else:
        text = str(content)

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-1] if lines else text.strip()


def _normalize_created_at(created_at: datetime) -> datetime:
    if created_at.tzinfo is None:
        return created_at.replace(tzinfo=timezone.utc)
    return created_at.astimezone(timezone.utc)


class SessionService:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def create_session(self, user_id: str, title: str) -> ChatSessionSummary:
        normalized_title = title.strip() or DEFAULT_SESSION_TITLE
        chat_session = ChatSession(user_id=user_id, title=normalized_title)
        self._session.add(chat_session)
        await self._session.commit()
        await self._session.refresh(chat_session)
        return ChatSessionSummary(
            id=chat_session.id,
            user_id=chat_session.user_id,
            title=chat_session.title,
            headline=chat_session.title,
            preview="",
            status="finished",
            created_at=chat_session.created_at,
            updated_at=chat_session.updated_at,
            last_message_at=chat_session.last_message_at,
        )

    async def list_sessions(self, user_id: str) -> list[ChatSessionSummary]:
        result = await self._session.execute(
            select(ChatSession).where(ChatSession.user_id == user_id).order_by(ChatSession.last_message_at.desc())
        )
        sessions = list(result.scalars().all())
        if not sessions:
            return []

        session_ids = [session.id for session in sessions]

        turn_state_rows = await self._session.execute(
            select(ChatTurnState.session_id, ChatTurnState.status, ChatTurnState.content)
            .where(ChatTurnState.user_id == user_id, ChatTurnState.session_id.in_(session_ids))
            .order_by(ChatTurnState.created_at.desc())
        )
        preview_by_session: dict[str, str] = {}
        running_session_ids: set[str] = set()
        for session_id, status, content in turn_state_rows.all():
            if status == "running":
                running_session_ids.add(session_id)
            if session_id not in preview_by_session:
                preview = _message_text_preview(content)
                if preview:
                    preview_by_session[session_id] = preview

        return [
            ChatSessionSummary(
                id=session.id,
                user_id=session.user_id,
                title=session.title,
                headline=session.title,
                preview=preview_by_session.get(session.id, ""),
                status="running" if session.id in running_session_ids else "finished",
                created_at=session.created_at,
                updated_at=session.updated_at,
                last_message_at=session.last_message_at,
            )
            for session in sessions
        ]

    async def get_session(self, user_id: str, session_id: str) -> ChatSession | None:
        result = await self._session.execute(
            select(ChatSession).where(ChatSession.id == session_id, ChatSession.user_id == user_id)
        )
        return result.scalar_one_or_none()

    async def delete_session(self, user_id: str, session_id: str) -> bool:
        session = await self.get_session(user_id, session_id)
        if session is None:
            return False

        await self._session.execute(delete(ChatTurnSource).where(ChatTurnSource.session_id == session_id))
        await self._session.execute(delete(ChatTurnFailure).where(ChatTurnFailure.session_id == session_id))
        await self._session.execute(delete(ChatTurnState).where(ChatTurnState.session_id == session_id))
        await self._session.delete(session)
        await self._session.commit()
        return True

    async def list_messages(self, user_id: str, session_id: str) -> list[ChatHistoryMessage]:
        session_row = await self._get_session_with_state(user_id, session_id)
        if session_row is None:
            return []

        history = session_row[1] or []

        citations_by_message = await self._citations_by_message(session_id)
        states_by_message = await self._states_by_message(user_id, session_id)

        messages: list[ChatHistoryMessage] = []
        # One run per turn; its run_id is the assistant message id that turn state and citations are keyed by.
        assistant_by_run: dict[str, tuple[datetime, str]] = {}
        for msg in history:
            run_id = msg.run_id or ""
            if isinstance(msg, ModelRequest):
                for part in msg.parts:
                    if isinstance(part, UserPromptPart) and isinstance(part.content, str):
                        messages.append(
                            ChatHistoryMessage(
                                id=f"{run_id}-user",
                                role="user",
                                content=part.content,
                                created_at=_normalize_created_at(part.timestamp),
                                citations=[],
                            )
                        )
                continue
            text = "".join(part.content for part in msg.parts if isinstance(part, TextPart))
            if text:
                created_at, prior = assistant_by_run.get(run_id, (_normalize_created_at(msg.timestamp), ""))
                assistant_by_run[run_id] = (created_at, prior + text)

        for run_id, (created_at, text) in assistant_by_run.items():
            state = states_by_message.get(run_id)
            messages.append(
                ChatHistoryMessage(
                    id=run_id,
                    role="assistant",
                    content=str(state["content"]) if state and state.get("content") else text,
                    created_at=created_at,
                    citations=citations_by_message.get(run_id, []),
                    status=state["status"] if state else "finished",
                    error=state.get("error") if state else None,
                )
            )

        known_ids = {message.id for message in messages}
        for assistant_message_id, state in states_by_message.items():
            if assistant_message_id in known_ids:
                continue
            messages.append(
                ChatHistoryMessage(
                    id=assistant_message_id,
                    role="assistant",
                    content=str(state.get("content") or ""),
                    created_at=_normalize_created_at(state["created_at"]),
                    citations=citations_by_message.get(assistant_message_id, []),
                    status=state.get("status") or "finished",
                    error=state.get("error"),
                )
            )

        return sorted(messages, key=lambda message: _normalize_created_at(message.created_at))

    async def _get_session_with_state(
        self, user_id: str, session_id: str
    ) -> tuple[ChatSession, list[ModelMessage] | None] | None:
        result = await self._session.execute(
            select(ChatSession).where(ChatSession.id == session_id, ChatSession.user_id == user_id)
        )
        chat_session = result.scalar_one_or_none()
        if chat_session is None:
            return None
        return chat_session, load_history(chat_session.agent_state)

    async def _citations_by_message(self, session_id: str) -> dict[str, list[dict[str, str]]]:
        history_rows = await self._session.execute(
            select(
                ChatTurnSource.assistant_message_id,
                ChatTurnSource.provider_id,
                ChatTurnSource.path,
            ).where(ChatTurnSource.session_id == session_id)
        )
        citations_by_message: dict[str, list[dict[str, str]]] = {}
        for assistant_message_id, provider_id, path in history_rows.all():
            citations_by_message.setdefault(assistant_message_id, [])
            citation = FileCitation(provider_id=provider_id, path=path, label=path).to_dict()
            if citation not in citations_by_message[assistant_message_id]:
                citations_by_message[assistant_message_id].append(citation)
        return citations_by_message

    async def _states_by_message(self, user_id: str, session_id: str) -> dict[str, dict[str, Any]]:
        turn_state_rows = await self._session.execute(
            select(
                ChatTurnState.assistant_message_id,
                ChatTurnState.status,
                ChatTurnState.content,
                ChatTurnState.error,
                ChatTurnState.created_at,
            )
            .where(ChatTurnState.session_id == session_id, ChatTurnState.user_id == user_id)
            .order_by(ChatTurnState.created_at.asc())
        )
        return {
            assistant_message_id: {
                "status": status,
                "content": content,
                "error": error,
                "created_at": created_at,
            }
            for assistant_message_id, status, content, error, created_at in turn_state_rows.all()
        }
