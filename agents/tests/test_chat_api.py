import asyncio
import importlib
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Any, cast

from fastapi.testclient import TestClient
import pytest

sys.path.append(str(Path(__file__).resolve().parents[1]))

from app.main import create_app
from db.session import get_db_session
from spaces.access import SpaceScope


@contextmanager
def settings_env(monkeypatch: pytest.MonkeyPatch, **env: str) -> Iterator[None]:
    settings_module = importlib.import_module("app.settings")

    for key, value in env.items():
        monkeypatch.setenv(key, value)

    settings_module.get_settings.cache_clear()
    try:
        yield
    finally:
        settings_module.get_settings.cache_clear()


def test_list_sessions_requires_authenticated_user() -> None:
    client = TestClient(create_app())

    response = client.get("/api/v1/chat/sessions")

    assert response.status_code == 401


def test_list_sessions_returns_sidebar_metadata(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()

    class StubSessionSummary:
        def __init__(self) -> None:
            self.id = "session-1"
            self.user_id = "alice"
            self.title = "Roadmap Review"
            self.headline = "Roadmap Review"
            self.preview = "Last preview line"
            self.status = "finished"
            self.created_at = "2026-04-12T00:00:00Z"
            self.updated_at = "2026-04-12T00:00:00Z"
            self.last_message_at = "2026-04-12T00:00:00Z"

    class StubSessionService:
        def __init__(self, session: object) -> None:
            del session

        async def list_sessions(self, user_id: str) -> list[StubSessionSummary]:
            assert user_id == "alice"
            return [StubSessionSummary()]

    monkeypatch.setattr("api.chat.SessionService", StubSessionService)

    with TestClient(app) as client:
        response = client.get("/api/v1/chat/sessions", headers={"X-Seraph-User": "alice"})

    assert response.status_code == 200
    assert response.json() == [
        {
            "id": "session-1",
            "user_id": "alice",
            "title": "Roadmap Review",
            "headline": "Roadmap Review",
            "preview": "Last preview line",
            "status": "finished",
            "created_at": "2026-04-12T00:00:00Z",
            "updated_at": "2026-04-12T00:00:00Z",
            "last_message_at": "2026-04-12T00:00:00Z",
        }
    ]


def test_delete_session_removes_owned_session(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()
    recorded: dict[str, str] = {}

    class StubSessionService:
        def __init__(self, session: object) -> None:
            del session

        async def delete_session(self, user_id: str, session_id: str) -> bool:
            recorded["user_id"] = user_id
            recorded["session_id"] = session_id
            return True

    monkeypatch.setattr("api.chat.SessionService", StubSessionService)

    with TestClient(app) as client:
        response = client.delete("/api/v1/chat/sessions/session-1", headers={"X-Seraph-User": "alice"})

    assert response.status_code == 204
    assert recorded == {"user_id": "alice", "session_id": "session-1"}


def test_chat_message_response_supports_structured_citations() -> None:
    from api.models import ChatMessageResponse

    response = ChatMessageResponse(
        id="assistant-1",
        role="assistant",
        content="See spec",
        created_at="2026-04-19T00:00:00Z",
        citations=[{"provider_id": "space-a", "path": "/team/spec.md", "label": "/team/spec.md"}],
    )

    assert response.citations[0].provider_id == "space-a"


@pytest.mark.asyncio
async def test_list_session_messages_returns_visible_history_with_citations(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()

    class StubHistoryMessage:
        def __init__(self, message_id: str, role: str, content: str, citations: list[dict[str, str]]) -> None:
            self.id = message_id
            self.role = role
            self.content = content
            self.citations = citations
            self.created_at = "2026-04-12T00:00:00Z"

    class StubSession:
        def __init__(self, session_id: str, user_id: str, title: str) -> None:
            self.id = session_id
            self.user_id = user_id
            self.title = title
            self.created_at = "2026-04-12T00:00:00Z"
            self.updated_at = "2026-04-12T00:00:00Z"
            self.last_message_at = "2026-04-12T00:00:00Z"

    class StubSessionService:
        def __init__(self, session: object) -> None:
            del session

        async def get_session(self, user_id: str, session_id: str) -> StubSession | None:
            if user_id == "alice" and session_id == "session-1":
                return StubSession(session_id, user_id, "Inbox")
            return None

        async def list_sessions(self, user_id: str) -> list[StubSession]:
            if user_id == "alice":
                return [StubSession("session-1", user_id, "Inbox")]
            return []

        async def list_messages(self, user_id: str, session_id: str) -> list[StubHistoryMessage]:
            assert user_id == "alice"
            assert session_id == "session-1"
            return [
                StubHistoryMessage("user-1", "user", "Find documents related to music", []),
                StubHistoryMessage(
                    "assistant-1",
                    "assistant",
                    "I found these documents related to music.",
                    [
                        {
                            "provider_id": "dirtest",
                            "path": "/Music/Maki Otsuki - Destiny/visit JPOP.ru.url",
                            "label": "/Music/Maki Otsuki - Destiny/visit JPOP.ru.url",
                        },
                        {
                            "provider_id": "dirtest",
                            "path": "/Music/Maki Otsuki - Destiny/visit aziophrenia.com - Japan and Korea - music, video, idols.url",
                            "label": "/Music/Maki Otsuki - Destiny/visit aziophrenia.com - Japan and Korea - music, video, idols.url",
                        },
                    ],
                ),
            ]

    monkeypatch.setattr("api.chat.SessionService", StubSessionService)

    with TestClient(app) as client:
        response = client.get("/api/v1/chat/sessions/session-1/messages", headers={"X-Seraph-User": "alice"})

    assert response.status_code == 200
    assert response.json() == [
        {
            "id": "user-1",
            "role": "user",
            "content": "Find documents related to music",
            "created_at": "2026-04-12T00:00:00Z",
            "citations": [],
        },
        {
            "id": "assistant-1",
            "role": "assistant",
            "content": "I found these documents related to music.",
            "created_at": "2026-04-12T00:00:00Z",
            "citations": [
                {
                    "provider_id": "dirtest",
                    "path": "/Music/Maki Otsuki - Destiny/visit JPOP.ru.url",
                    "label": "/Music/Maki Otsuki - Destiny/visit JPOP.ru.url",
                },
                {
                    "provider_id": "dirtest",
                    "path": "/Music/Maki Otsuki - Destiny/visit aziophrenia.com - Japan and Korea - music, video, idols.url",
                    "label": "/Music/Maki Otsuki - Destiny/visit aziophrenia.com - Japan and Korea - music, video, idols.url",
                },
            ],
        },
    ]


@pytest.mark.asyncio
async def test_session_service_uses_persisted_message_payload_id_for_citations() -> None:
    from chat.session_service import SessionService
    from documents.models import Base, ChatSession, ChatTurnSource
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
    message_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.MessageTable
    session_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.SessionTable
    user_table = sqlalchemy_memory.AsyncSQLAlchemyMemory.UserTable

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(sqlalchemy_memory.Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db:
        db.add(ChatSession(id="session-1", user_id="alice", title="Inbox"))
        db.add(user_table(id="alice"))
        db.add(session_table(id="session-1", user_id="alice"))
        db.add(
            message_table(
                id="alice-session-1-row-id",
                session_id="session-1",
                index=1,
                msg={
                    "id": "assistant-1",
                    "name": "seraph-documents",
                    "role": "assistant",
                    "content": [{"type": "text", "text": "hello"}],
                    "timestamp": "2026-04-12T00:00:01",
                },
            )
        )
        db.add(
            ChatTurnSource(
                session_id="session-1",
                assistant_message_id="assistant-1",
                provider_id="dirtest",
                path="/Music/example.url",
            )
        )
        await db.commit()

        service = SessionService(db)
        messages = await service.list_messages("alice", "session-1")

    assert len(messages) == 1
    assert messages[0].id == "assistant-1"
    assert messages[0].citations == [
        {"provider_id": "dirtest", "path": "/Music/example.url", "label": "/Music/example.url"}
    ]

    await engine.dispose()


def test_create_session_defaults_to_anonymous_when_auth_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    recorded: dict[str, str] = {}

    with settings_env(monkeypatch, SERAPH_AUTH_ENABLED="false"):
        app = create_app()

        class StubSession:
            def __init__(self) -> None:
                self.id = "session-1"
                self.user_id = "anonymous"
                self.title = "Anonymous session"
                self.created_at = "2026-04-11T00:00:00Z"
                self.updated_at = "2026-04-11T00:00:00Z"
                self.last_message_at = "2026-04-11T00:00:00Z"

        class StubSessionService:
            def __init__(self, session: object) -> None:
                del session

            async def create_session(self, user_id: str, title: str) -> StubSession:
                recorded["user_id"] = user_id
                recorded["title"] = title
                return StubSession()

        monkeypatch.setattr("api.chat.SessionService", StubSessionService)

        with TestClient(app) as client:
            response = client.post("/api/v1/chat/sessions", json={"title": "Anonymous session"})

    assert response.status_code == 201
    assert response.json()["user_id"] == "anonymous"
    assert recorded == {"user_id": "anonymous", "title": "Anonymous session"}


@pytest.mark.asyncio
async def test_create_and_list_sessions_for_authenticated_user(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()
    sessions: list[dict[str, str]] = []

    class StubSession:
        def __init__(self, payload: dict[str, str]) -> None:
            self.id = payload["id"]
            self.user_id = payload["user_id"]
            self.title = payload["title"]
            self.created_at = "2026-04-11T00:00:00Z"
            self.updated_at = "2026-04-11T00:00:00Z"
            self.last_message_at = "2026-04-11T00:00:00Z"

    class StubSessionService:
        def __init__(self, session: object) -> None:
            del session

        async def create_session(self, user_id: str, title: str) -> StubSession:
            payload = {"id": "session-1", "user_id": user_id, "title": title}
            sessions.append(payload)
            return StubSession(payload)

        async def list_sessions(self, user_id: str) -> list[StubSession]:
            return [StubSession(session) for session in sessions if session["user_id"] == user_id]

    monkeypatch.setattr("api.chat.SessionService", StubSessionService)

    with TestClient(app) as client:
        create_response = client.post(
            "/api/v1/chat/sessions",
            headers={"X-Seraph-User": "alice"},
            json={"title": "Inbox"},
        )

        assert create_response.status_code == 201
        created_session = create_response.json()
        assert created_session["title"] == "Inbox"
        assert created_session["user_id"] == "alice"

        list_response = client.get("/api/v1/chat/sessions", headers={"X-Seraph-User": "alice"})

        assert list_response.status_code == 200
        assert list_response.json() == [created_session]


@pytest.mark.asyncio
async def test_create_message_accepts_owned_session(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()
    sessions = {"session-1": "alice"}
    recorded: dict[str, object] = {}

    class StubSession:
        def __init__(self, session_id: str, user_id: str, title: str) -> None:
            self.id = session_id
            self.user_id = user_id
            self.title = title
            self.created_at = "2026-04-11T00:00:00Z"
            self.updated_at = "2026-04-11T00:00:00Z"
            self.last_message_at = "2026-04-11T00:00:00Z"

    class StubSessionService:
        def __init__(self, session: object) -> None:
            del session

        async def create_session(self, user_id: str, title: str) -> StubSession:
            return StubSession("session-1", user_id, title)

        async def get_session(self, user_id: str, session_id: str) -> StubSession | None:
            owner = sessions.get(session_id)
            if owner != user_id:
                return None
            return StubSession(session_id, user_id, "Inbox")

    async def fake_accept_pending_turn(
        *, db: object, session_id: str, user_id: str, message: str, title_summarizer=None
    ):
        recorded["db"] = db
        recorded["session_id"] = session_id
        recorded["user_id"] = user_id
        recorded["message"] = message
        recorded["title_summarizer"] = title_summarizer

    monkeypatch.setattr("api.chat.SessionService", StubSessionService)
    monkeypatch.setattr("api.chat._accept_pending_turn", fake_accept_pending_turn)

    with TestClient(app) as client:
        create_response = client.post(
            "/api/v1/chat/sessions",
            headers={"X-Seraph-User": "alice"},
            json={"title": "Inbox"},
        )
        assert create_response.status_code == 201
        session_id = create_response.json()["id"]

        message_response = client.post(
            f"/api/v1/chat/sessions/{session_id}/messages",
            headers={"X-Seraph-User": "alice"},
            json={"message": "What changed?"},
        )

        assert message_response.status_code == 202
        assert message_response.json() == {"accepted": True}
        assert recorded["session_id"] == session_id
        assert recorded["user_id"] == "alice"
        assert recorded["message"] == "What changed?"


@pytest.mark.asyncio
async def test_accept_pending_turn_keeps_multiple_records() -> None:
    chat_module = importlib.import_module("api.chat")
    added: list[Any] = []
    statements: list[object] = []
    commits = 0

    class StubDb:
        def add(self, obj: object) -> None:
            added.append(obj)

        async def execute(self, statement: object) -> None:
            statements.append(statement)

        async def commit(self) -> None:
            nonlocal commits
            commits += 1

        async def refresh(self, obj: object) -> None:
            del obj

    db = StubDb()

    first = await chat_module._accept_pending_turn(db=db, session_id="session-1", user_id="alice", message="first")
    second = await chat_module._accept_pending_turn(db=db, session_id="session-1", user_id="alice", message="second")

    assert [cast(Any, turn).message for turn in added] == ["first", "second"]
    assert first.id != second.id
    assert len(statements) == 2
    assert commits == 2


@pytest.mark.asyncio
async def test_accept_pending_turn_updates_last_message_time() -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, object] = {}

    class StubDb:
        def add(self, obj: object) -> None:
            recorded["added"] = obj

        async def execute(self, statement: object) -> None:
            recorded["statement"] = statement

        async def commit(self) -> None:
            recorded["committed"] = True

        async def refresh(self, obj: object) -> None:
            recorded["refreshed"] = obj

    pending_turn = await chat_module._accept_pending_turn(
        db=StubDb(), session_id="session-1", user_id="alice", message="hello"
    )

    assert pending_turn.message == "hello"
    assert recorded["statement"] is not None
    assert recorded["committed"] is True


@pytest.mark.asyncio
async def test_accept_pending_turn_promotes_default_title_to_llm_summary() -> None:
    from documents.models import Base, ChatSession
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    chat_module = importlib.import_module("api.chat")

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db:
        db.add(ChatSession(id="session-1", user_id="alice", title="New conversation"))
        await db.commit()

        class StubSummarizer:
            async def summarize(self, message: str) -> str:
                assert message == "   Draft roadmap for distributed search rollout with milestones and risks   "
                return "Search rollout roadmap"

        await chat_module._accept_pending_turn(
            db=db,
            session_id="session-1",
            user_id="alice",
            message="   Draft roadmap for distributed search rollout with milestones and risks   ",
            title_summarizer=StubSummarizer(),
        )

        persisted_session = await db.get(ChatSession, "session-1")

    assert persisted_session is not None
    assert persisted_session.title == "Search rollout roadmap"

    await engine.dispose()


@pytest.mark.asyncio
async def test_accept_pending_turn_falls_back_to_local_summary_when_llm_title_generation_fails() -> None:
    from documents.models import Base, ChatSession
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    chat_module = importlib.import_module("api.chat")

    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db:
        db.add(ChatSession(id="session-1", user_id="alice", title="New conversation"))
        await db.commit()

        class FailingSummarizer:
            async def summarize(self, message: str) -> str:
                raise RuntimeError(f"cannot summarize {message}")

        await chat_module._accept_pending_turn(
            db=db,
            session_id="session-1",
            user_id="alice",
            message="   Draft roadmap for distributed search rollout with milestones and risks   ",
            title_summarizer=FailingSummarizer(),
        )

        persisted_session = await db.get(ChatSession, "session-1")

    assert persisted_session is not None
    assert persisted_session.title == "Draft roadmap for distributed search rollout with milestones and risks"

    await engine.dispose()


@pytest.mark.asyncio
async def test_accept_pending_turn_rolls_back_when_commit_fails() -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, object] = {}

    class StubDb:
        def add(self, obj: object) -> None:
            recorded["added"] = obj

        async def execute(self, statement: object) -> None:
            recorded["statement"] = statement

        async def commit(self) -> None:
            raise RuntimeError("commit failed")

        async def rollback(self) -> None:
            recorded["rolled_back"] = True

        async def refresh(self, obj: object) -> None:
            recorded["refreshed"] = obj

    with pytest.raises(RuntimeError, match="commit failed"):
        await chat_module._accept_pending_turn(db=StubDb(), session_id="session-1", user_id="alice", message="hello")

    assert recorded["statement"] is not None
    assert recorded["rolled_back"] is True
    assert "refreshed" not in recorded


@pytest.mark.asyncio
async def test_accept_pending_turn_rolls_back_when_commit_is_cancelled() -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, object] = {}

    class StubDb:
        def add(self, obj: object) -> None:
            recorded["added"] = obj

        async def execute(self, statement: object) -> None:
            recorded["statement"] = statement

        async def commit(self) -> None:
            raise asyncio.CancelledError()

        async def rollback(self) -> None:
            recorded["rolled_back"] = True

        async def refresh(self, obj: object) -> None:
            recorded["refreshed"] = obj

    with pytest.raises(asyncio.CancelledError):
        await chat_module._accept_pending_turn(db=StubDb(), session_id="session-1", user_id="alice", message="hello")

    assert recorded["statement"] is not None
    assert recorded["rolled_back"] is True
    assert "refreshed" not in recorded


def test_create_app_wires_runtime_agent_factory() -> None:
    app = create_app()

    assert app.state.agent_factory is not None


def test_create_app_starts_and_stops_ingestion_service(monkeypatch: pytest.MonkeyPatch) -> None:
    main_module = importlib.import_module("app.main")
    recorded: list[str] = []

    class StubIngestionService:
        async def start(self) -> None:
            recorded.append("start")

        async def stop(self) -> None:
            recorded.append("stop")

    monkeypatch.setattr(main_module, "create_ingestion_service", lambda settings: StubIngestionService())

    app = main_module.create_app()
    with TestClient(app):
        assert recorded == ["start"]

    assert recorded == ["start", "stop"]


@pytest.mark.asyncio
async def test_document_status_returns_indexed_documents(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()

    class StubDocument:
        def __init__(self, doc_id: str, provider_id: str, path: str) -> None:
            self.id = doc_id
            self.provider_id = provider_id
            self.path = path
            self.ingest_status = "indexed"
            self.last_error = None

    class StubScalars:
        def all(self) -> list[StubDocument]:
            return [
                StubDocument("doc-1", "provider-a", "/team/spec.md"),
                StubDocument("doc-2", "provider-a", "/private/secret.md"),
                StubDocument("doc-3", "provider-b", "/team/spec.md"),
            ]

    class StubResult:
        def scalars(self) -> StubScalars:
            return StubScalars()

    class StubDb:
        async def execute(self, statement: object) -> StubResult:
            del statement
            return StubResult()

    async def override_db_session() -> StubDb:
        return StubDb()

    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str) -> list[SpaceScope]:
            assert user_id == "alice"
            return [SpaceScope(provider_id="provider-a", path_prefix="/team")]

    app.dependency_overrides[get_db_session] = override_db_session
    app.state.spaces_client = StubSpacesClient()

    with TestClient(app) as client:
        response = client.get("/api/v1/documents/status", headers={"X-Seraph-User": "alice"})

    assert response.status_code == 200
    assert response.json() == [
        {
            "id": "doc-1",
            "provider_id": "provider-a",
            "path": "/team/spec.md",
            "ingest_status": "indexed",
            "last_error": None,
        }
    ]


@pytest.mark.asyncio
async def test_lazy_spaces_client_initialization_is_synchronized(monkeypatch: pytest.MonkeyPatch) -> None:
    main_module = importlib.import_module("app.main")
    connect_calls: list[str] = []

    class StubClient:
        async def get_scopes_for_user(self, user_id: str) -> list[str]:
            return [user_id]

    async def fake_connect(self):
        connect_calls.append("connect")
        await asyncio.sleep(0)
        return object()

    monkeypatch.setattr(main_module._LazySpacesClient, "_connect_nats", fake_connect)
    monkeypatch.setattr(main_module, "SpacesClient", lambda nc: StubClient())

    client = main_module._LazySpacesClient("nats://example")
    results = await asyncio.gather(client.get_scopes_for_user("alice"), client.get_scopes_for_user("alice"))

    assert results == [["alice"], ["alice"]]
    assert connect_calls == ["connect"]
