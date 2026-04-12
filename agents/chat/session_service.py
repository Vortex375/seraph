import importlib
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from documents.models import ChatSession, ChatTurnSource


@dataclass(frozen=True)
class ChatHistoryMessage:
    id: str
    role: str
    content: str
    created_at: datetime
    citations: list[str]


class SessionService:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def create_session(self, user_id: str, title: str) -> ChatSession:
        chat_session = ChatSession(user_id=user_id, title=title)
        self._session.add(chat_session)
        await self._session.commit()
        await self._session.refresh(chat_session)
        return chat_session

    async def list_sessions(self, user_id: str) -> list[ChatSession]:
        result = await self._session.execute(select(ChatSession).where(ChatSession.user_id == user_id))
        return list(result.scalars().all())

    async def get_session(self, user_id: str, session_id: str) -> ChatSession | None:
        result = await self._session.execute(
            select(ChatSession).where(ChatSession.id == session_id, ChatSession.user_id == user_id)
        )
        return result.scalar_one_or_none()

    async def list_messages(self, user_id: str, session_id: str) -> list[ChatHistoryMessage]:
        session = await self.get_session(user_id, session_id)
        if session is None:
            return []

        sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
        message_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.MessageTable

        history_rows = await self._session.execute(
            select(
                ChatTurnSource.assistant_message_id,
                ChatTurnSource.path,
            ).where(ChatTurnSource.session_id == session_id)
        )
        citations_by_message: dict[str, list[str]] = {}
        for assistant_message_id, path in history_rows.all():
            citations_by_message.setdefault(assistant_message_id, [])
            if path not in citations_by_message[assistant_message_id]:
                citations_by_message[assistant_message_id].append(path)

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
