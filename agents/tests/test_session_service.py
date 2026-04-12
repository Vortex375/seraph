import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from chat.session_service import SessionService
from db.session import _build_async_db_url, get_postgres_db
from documents.models import Base


@pytest.mark.asyncio
async def test_create_session_belongs_to_request_user() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        service = SessionService(db_session)
        session = await service.create_session(user_id="alice", title="Inbox")

    assert session.user_id == "alice"
    assert session.title == "Inbox"

    await engine.dispose()


def test_build_async_db_url_rejects_unsupported_driver() -> None:
    with pytest.raises(ValueError, match="unsupported async database URL"):
        _build_async_db_url("sqlite:///tmp/agents.db")


def test_get_postgres_db_fails_immediately_for_legacy_use() -> None:
    with pytest.raises(RuntimeError, match="temporary compatibility shim"):
        get_postgres_db()
