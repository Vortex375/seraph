from __future__ import annotations

from typing import Any

from agentscope.state import AgentState
from sqlalchemy.ext.asyncio import AsyncSession

from db.session import SessionLocal
from documents.models import ChatSession


class AgentStateStore:
    """Load and persist AgentScope 2.x AgentState for chat sessions."""

    def __init__(self, session: AsyncSession | None = None) -> None:
        self._session = session

    async def load(self, user_id: str, session_id: str) -> AgentState | None:
        """Load the saved state for a session, if any."""
        async with self._session_context() as session:
            row = await session.get(ChatSession, session_id)
            if row is None or row.user_id != user_id:
                return None
            raw_state = row.agent_state
            if not raw_state:
                return None
            return AgentState.model_validate(raw_state)

    async def save(self, user_id: str, session_id: str, state: AgentState) -> None:
        """Persist the current agent state for a session."""
        async with self._session_context() as session:
            row = await session.get(ChatSession, session_id)
            if row is None or row.user_id != user_id:
                return
            row.agent_state = state.model_dump(mode="json")
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
