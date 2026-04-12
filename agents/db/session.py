from collections.abc import AsyncIterator
from dataclasses import dataclass

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from db.url import db_url


def _build_async_db_url(url: str) -> str:
    if url.startswith("postgresql+psycopg://"):
        return url.replace("postgresql+psycopg://", "postgresql+psycopg_async://", 1)
    if url.startswith("postgresql+psycopg_async://"):
        return url

    raise ValueError(f"unsupported async database URL: {url}")


engine = create_async_engine(_build_async_db_url(db_url), future=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


@dataclass(frozen=True)
class _LegacyPostgresDbCompatibility:
    db_url: str
    contents_table: str | None = None


def get_postgres_db(contents_table: str | None = None) -> _LegacyPostgresDbCompatibility:
    raise RuntimeError(
        "get_postgres_db() is a temporary compatibility shim during the AgentScope refactor and cannot be used in "
        f"the Task 2 intermediate state (contents_table={contents_table!r})"
    )


async def get_db_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session
