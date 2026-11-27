from __future__ import annotations

from typing import Any

from pydantic import ValidationError
from pydantic_ai import ModelMessage, ModelMessagesTypeAdapter
from sqlalchemy.ext.asyncio import AsyncSession

from db.session import SessionLocal
from documents.models import ChatSession


def load_history(raw_state: Any) -> list[ModelMessage] | None:
    """Parse a persisted Pydantic AI message history; unreadable state (e.g. pre-Pydantic-AI) yields ``None``."""
    if not raw_state:
        return None
    try:
        return ModelMessagesTypeAdapter.validate_python(raw_state)
    except ValidationError:
        return None


class AgentStateStore:
    """Load and persist the Pydantic AI message history of chat sessions."""

    def __init__(self, session: AsyncSession | None = None) -> None:
        self._session = session

    async def load(self, user_id: str, session_id: str) -> list[ModelMessage] | None:
        """Load the saved history for a session, if any."""
        async with self._session_context() as session:
            row = await session.get(ChatSession, session_id)
            if row is None or row.user_id != user_id:
                return None
            return load_history(row.agent_state)

    async def save(self, user_id: str, session_id: str, state: list[ModelMessage]) -> None:
        """Persist the current message history for a session."""
        async with self._session_context() as session:
            row = await session.get(ChatSession, session_id)
            if row is None or row.user_id != user_id:
                return
            row.agent_state = ModelMessagesTypeAdapter.dump_python(state, mode="json")
            await session.commit()

    def _session_context(self) -> Any:
        if self._session is not None:
            return _ExistingSession(self._session)
        return SessionLocal()


class _ExistingSession:
    """Compatibility shim to treat an injected session like an async context manager."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def __aenter__(self) -> AsyncSession:
        return self._session

    async def __aexit__(self, exc_type: Any, exc: Any, tb: Any) -> None:
        return None
