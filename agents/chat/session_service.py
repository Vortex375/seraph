import importlib
from dataclasses import dataclass
from datetime import datetime
from typing import Protocol

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from chat.file_models import FileCitation
from documents.models import ChatSession, ChatTurnFailure, ChatTurnSource, PendingChatTurn


@dataclass(frozen=True)
class ChatHistoryMessage:
    id: str
    role: str
    content: str
    created_at: datetime
    citations: list[dict[str, str]]


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


class SessionTitleSummarizer(Protocol):
    async def summarize(self, message: str) -> str: ...


def summarize_session_title(message: str) -> str:
    normalized = " ".join(message.strip().split())
    if not normalized:
        return DEFAULT_SESSION_TITLE
    return normalized[:80].rstrip()


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


def _message_preview_from_record(role: object, content: object) -> str:
    if role not in {"user", "assistant"}:
        return ""
    if role == "user" and isinstance(content, list):
        joined = "".join(
            block.get("text", "") for block in content if isinstance(block, dict) and block.get("type") == "text"
        )
        if joined.startswith("<retrieved_knowledge>"):
            return ""
    return _message_text_preview(content)


class SessionService:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def create_session(self, user_id: str, title: str) -> ChatSession:
        normalized_title = title.strip() or DEFAULT_SESSION_TITLE
        chat_session = ChatSession(user_id=user_id, title=normalized_title)
        self._session.add(chat_session)
        await self._session.commit()
        await self._session.refresh(chat_session)
        return chat_session

    async def list_sessions(self, user_id: str) -> list[ChatSessionSummary]:
        result = await self._session.execute(
            select(ChatSession).where(ChatSession.user_id == user_id).order_by(ChatSession.last_message_at.desc())
        )
        sessions = list(result.scalars().all())
        if not sessions:
            return []

        session_ids = [session.id for session in sessions]

        pending_rows = await self._session.execute(
            select(PendingChatTurn.session_id).where(
                PendingChatTurn.user_id == user_id, PendingChatTurn.session_id.in_(session_ids)
            )
        )
        running_session_ids = {session_id for (session_id,) in pending_rows.all()}

        sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
        message_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.MessageTable
        agentscope_messages = await self._session.execute(
            select(message_table.session_id, message_table.msg, message_table.index)
            .where(message_table.session_id.in_(session_ids))
            .order_by(message_table.session_id.asc(), message_table.index.asc())
        )
        preview_by_session: dict[str, str] = {}
        for session_id, raw_msg, _index in agentscope_messages.all():
            if not isinstance(raw_msg, dict):
                continue
            preview = _message_preview_from_record(raw_msg.get("role"), raw_msg.get("content"))
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

        sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
        message_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.MessageTable
        session_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.SessionTable

        await self._session.execute(delete(PendingChatTurn).where(PendingChatTurn.session_id == session_id))
        await self._session.execute(delete(ChatTurnSource).where(ChatTurnSource.session_id == session_id))
        await self._session.execute(delete(ChatTurnFailure).where(ChatTurnFailure.session_id == session_id))
        await self._session.execute(delete(message_table).where(message_table.session_id == session_id))
        await self._session.execute(
            delete(session_table).where(session_table.id == session_id, session_table.user_id == user_id)
        )
        await self._session.delete(session)
        await self._session.commit()
        return True

    async def list_messages(self, user_id: str, session_id: str) -> list[ChatHistoryMessage]:
        session = await self.get_session(user_id, session_id)
        if session is None:
            return []

        sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
        message_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.MessageTable

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

        agentscope_messages = await self._session.execute(
            select(
                message_table.id,
                message_table.msg,
                message_table.index,
            )
            .where(message_table.session_id == session_id)
            .order_by(message_table.index.asc())
        )

        messages: list[ChatHistoryMessage] = []
        for row_message_id, raw_msg, _index in agentscope_messages.all():
            if not isinstance(raw_msg, dict):
                continue
            message_id = str(raw_msg.get("id") or row_message_id)
            role = raw_msg.get("role")
            if role not in {"user", "assistant"}:
                continue
            content = raw_msg.get("content")
            if role == "user" and isinstance(content, list):
                joined = "".join(
                    block.get("text", "")
                    for block in content
                    if isinstance(block, dict) and block.get("type") == "text"
                )
                if joined.startswith("<retrieved_knowledge>"):
                    continue
                text = joined
            elif isinstance(content, str):
                text = content
            elif isinstance(content, list):
                text = "".join(
                    block.get("text", "")
                    for block in content
                    if isinstance(block, dict) and block.get("type") == "text"
                )
            else:
                text = str(content)

            timestamp = raw_msg.get("timestamp")
            created_at = datetime.fromisoformat(str(timestamp)) if timestamp else session.created_at

            messages.append(
                ChatHistoryMessage(
                    id=message_id,
                    role=role,
                    content=text,
                    created_at=created_at,
                    citations=citations_by_message.get(message_id, []) if role == "assistant" else [],
                )
            )

        return messages
