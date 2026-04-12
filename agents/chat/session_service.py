from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from documents.models import ChatSession


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
