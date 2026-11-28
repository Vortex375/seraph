from collections.abc import AsyncIterator, Callable, Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic_ai.models.function import FunctionModel
from sqlalchemy import create_engine
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from api.chat import get_agent_factory
from api.documents import get_spaces_client
from app.main import create_app
from app.settings import Settings
from chat.agent_factory import AgentFactory
from db.session import get_db_session, get_session_factory
from documents.models import Base
from tests.support import StubRetrieval, StubSpaces


@pytest.fixture
def session_factory(tmp_path: Path) -> Iterator[async_sessionmaker[AsyncSession]]:
    """A file-backed SQLite database; NullPool keeps it usable from both pytest's and TestClient's event loops."""
    path = tmp_path / "agents.db"
    sync_engine = create_engine(f"sqlite:///{path}")
    Base.metadata.create_all(sync_engine)
    sync_engine.dispose()
    yield async_sessionmaker(
        create_async_engine(f"sqlite+aiosqlite:///{path}", poolclass=NullPool), expire_on_commit=False
    )


@pytest.fixture
def make_factory() -> Callable[..., AgentFactory]:
    def make(
        stream_function: Any, spaces: StubSpaces | None = None, retrieval: Any = None, title_function: Any = None
    ) -> AgentFactory:
        """``stream_function`` scripts the chat agent; ``title_function`` the non-streamed title request."""
        return AgentFactory(
            model=FunctionModel(function=title_function, stream_function=stream_function),
            retrieval_service=retrieval or StubRetrieval(),
            spaces_client=spaces or StubSpaces(),
        )

    return make


@pytest.fixture
def app(session_factory: async_sessionmaker[AsyncSession], make_factory: Callable[..., AgentFactory]) -> FastAPI:
    """The real app with its DB, agent and spaces dependencies pointed at test doubles.

    The agent replies "ok"; assign ``app.state.factory`` to script a different model.
    """

    async def reply_ok(messages: Any, info: Any) -> AsyncIterator[str]:
        yield "ok"

    app = create_app(Settings())
    app.state.factory = make_factory(reply_ok)

    async def db_session() -> AsyncIterator[AsyncSession]:
        async with session_factory() as session:
            yield session

    app.dependency_overrides[get_db_session] = db_session
    app.dependency_overrides[get_session_factory] = lambda: session_factory
    app.dependency_overrides[get_agent_factory] = lambda: app.state.factory
    app.dependency_overrides[get_spaces_client] = lambda: StubSpaces()
    return app


@pytest.fixture
def client(app: FastAPI) -> Iterator[TestClient]:
    # No `with`: the lifespan (Postgres schema, NATS, ingestion) does not run.
    client = TestClient(app, headers={"X-Seraph-User": "alice"})
    yield client
    client.close()
