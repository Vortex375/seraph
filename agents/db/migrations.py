"""Simple additive database migrations for the agents service.

These migrations run after ``Base.metadata.create_all`` on startup. They are
intentionally minimal and only cover additive schema changes that
``create_all`` cannot apply to existing tables (e.g. adding a missing
column). Future, more complex schema changes may require a full migration
framework such as Alembic.
"""

from __future__ import annotations

import logging

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection

logger = logging.getLogger(__name__)

_MIGRATIONS: list[tuple[str, str]] = [
    (
        "0001_add_chat_session_agent_state",
        """
        ALTER TABLE chat_sessions
        ADD COLUMN IF NOT EXISTS agent_state JSON DEFAULT '{}'::json;
        """,
    ),
]


async def apply_migrations(conn: AsyncConnection) -> None:
    """Apply all additive migrations idempotently."""
    for name, sql in _MIGRATIONS:
        await conn.run_sync(lambda sync_conn: sync_conn.execute(text(sql)))
        logger.info("Applied migration: %s", name)
