import json
from collections.abc import AsyncIterator, Callable, Iterator
from typing import Any

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from pydantic_ai import ModelMessage
from pydantic_ai.models.function import AgentInfo
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from api.documents import get_spaces_client
from app import main as main_module
from app.settings import Settings
from chat.agent_factory import AgentFactory
from documents.models import IndexedDocument
from spaces.access import SpaceScope
from tests.support import SPEC_CITATION, StubSpaces, search_then_answer


def _events(body: str) -> list[dict[str, Any]]:
    return [json.loads(line.removeprefix("data: ")) for line in body.splitlines() if line.startswith("data: ")]


def _create_session(client: TestClient, title: str = "Inbox") -> dict[str, Any]:
    response = client.post("/api/v1/chat/sessions", json={"title": title})
    assert response.status_code == 201
    session: dict[str, Any] = response.json()
    return session


def test_chat_routes_require_an_authenticated_user(client: TestClient) -> None:
    response = client.get("/api/v1/chat/sessions", headers={"X-Seraph-User": ""})

    assert response.status_code == 401


def test_create_and_list_sessions_for_the_user(client: TestClient) -> None:
    created = _create_session(client, "Roadmap Review")

    assert created["user_id"] == "alice"
    assert (created["title"], created["headline"], created["preview"], created["status"]) == (
        "Roadmap Review",
        "Roadmap Review",
        "",
        "finished",
    )
    assert client.get("/api/v1/chat/sessions").json() == [created]
    assert client.get("/api/v1/chat/sessions", headers={"X-Seraph-User": "bob"}).json() == []


def test_sessions_default_to_anonymous_when_auth_is_disabled(
    session_factory: async_sessionmaker[AsyncSession], monkeypatch: pytest.MonkeyPatch, client: TestClient
) -> None:
    from app.settings import get_settings

    monkeypatch.setenv("SERAPH_AUTH_ENABLED", "false")
    get_settings.cache_clear()
    try:
        response = client.post("/api/v1/chat/sessions", json={"title": "Anonymous"}, headers={"X-Seraph-User": ""})
    finally:
        get_settings.cache_clear()

    assert response.status_code == 201
    assert response.json()["user_id"] == "anonymous"


def test_delete_session_only_removes_the_users_own_session(client: TestClient) -> None:
    session_id = _create_session(client)["id"]

    assert client.delete(f"/api/v1/chat/sessions/{session_id}", headers={"X-Seraph-User": "bob"}).status_code == 404
    assert client.delete(f"/api/v1/chat/sessions/{session_id}").status_code == 204
    assert client.get("/api/v1/chat/sessions").json() == []


def test_stream_reply_then_list_it_with_citations(
    app: FastAPI, client: TestClient, make_factory: Callable[..., AgentFactory]
) -> None:
    app.state.factory = make_factory(search_then_answer)
    session_id = _create_session(client)["id"]

    with client.stream(
        "POST", f"/api/v1/chat/sessions/{session_id}/messages/stream", json={"message": "When is launch?"}
    ) as response:
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/event-stream")
        events = _events(response.read().decode())

    turn_id = events[0]["id"]
    assert [(e["type"], e.get("content")) for e in events] == [
        ("delta", "July "),
        ("delta", "first"),
        ("done", None),
    ]
    assert all(e["id"] == turn_id and e["role"] == "assistant" and e["citations"] == [SPEC_CITATION] for e in events)

    messages = client.get(f"/api/v1/chat/sessions/{session_id}/messages").json()
    assert [(m["id"], m["role"], m["content"], m["status"], m["citations"]) for m in messages] == [
        (f"{turn_id}-user", "user", "When is launch?", "finished", []),
        (turn_id, "assistant", "July first", "finished", [SPEC_CITATION]),
    ]
    assert client.get("/api/v1/chat/sessions").json()[0]["preview"] == "July first"


def test_stream_reports_model_failure_as_error_event(
    app: FastAPI, client: TestClient, make_factory: Callable[..., AgentFactory]
) -> None:
    async def fail(messages: list[ModelMessage], info: AgentInfo) -> AsyncIterator[str]:
        del messages, info
        raise RuntimeError("provider exploded")
        yield ""

    app.state.factory = make_factory(fail)
    session_id = _create_session(client)["id"]

    response = client.post(f"/api/v1/chat/sessions/{session_id}/messages/stream", json={"message": "hi"})

    assert [(e["type"], e["content"]) for e in _events(response.text)] == [("error", "provider exploded")]
    [message] = client.get(f"/api/v1/chat/sessions/{session_id}/messages").json()
    assert (message["status"], message["error"]) == ("failed", "provider exploded")


@pytest.mark.parametrize("path", ["messages/stream", "messages"])
def test_session_routes_404_for_another_users_session(client: TestClient, path: str) -> None:
    session_id = _create_session(client)["id"]

    if path == "messages":
        response = client.get(f"/api/v1/chat/sessions/{session_id}/messages", headers={"X-Seraph-User": "bob"})
    else:
        response = client.post(
            f"/api/v1/chat/sessions/{session_id}/{path}", json={"message": "hi"}, headers={"X-Seraph-User": "bob"}
        )

    assert response.status_code == 404


def test_legacy_message_routes_are_gone(client: TestClient) -> None:
    session_id = _create_session(client)["id"]

    assert client.get(f"/api/v1/chat/sessions/{session_id}/stream").status_code == 404
    assert client.post(f"/api/v1/chat/sessions/{session_id}/messages", json={"message": "hi"}).status_code == 405


@pytest.mark.asyncio
async def test_document_status_only_lists_documents_in_the_users_spaces(
    app: FastAPI, client: TestClient, session_factory: async_sessionmaker[AsyncSession]
) -> None:
    async with session_factory() as db:
        for doc_id, provider_id, path in [
            ("doc-1", "provider-a", "/team/spec.md"),
            ("doc-2", "provider-a", "/private/secret.md"),
            ("doc-3", "provider-b", "/team/spec.md"),
        ]:
            db.add(
                IndexedDocument(
                    id=doc_id,
                    provider_id=provider_id,
                    path=path,
                    mime="text/markdown",
                    size=1,
                    mod_time=0,
                    content_hash="h",
                )
            )
        await db.commit()
    app.dependency_overrides[get_spaces_client] = lambda: StubSpaces(
        [SpaceScope(provider_id="provider-a", path_prefix="/team")]
    )

    response = client.get("/api/v1/documents/status")

    assert response.json() == [
        {
            "id": "doc-1",
            "provider_id": "provider-a",
            "path": "/team/spec.md",
            "ingest_status": "indexed",
            "last_error": None,
        },
    ]


@pytest.fixture
def lifespan_calls(monkeypatch: pytest.MonkeyPatch) -> Iterator[list[str]]:
    calls: list[str] = []

    class StubNats:
        async def close(self) -> None:
            calls.append("nats closed")

    class StubIngestion:
        async def start(self) -> None:
            calls.append("ingestion started")

        async def stop(self) -> None:
            calls.append("ingestion stopped")

    async def init_schema() -> None:
        calls.append("schema")

    async def connect() -> StubNats:
        calls.append("nats connected")
        return StubNats()

    monkeypatch.setattr(main_module, "initialize_database_schema", init_schema)
    monkeypatch.setattr(main_module, "connect_nats_from_env", connect)
    monkeypatch.setattr(main_module, "create_ingestion_service", StubIngestion)
    yield calls


def test_lifespan_wires_runtime_and_shuts_down_in_reverse_order(lifespan_calls: list[str]) -> None:
    app = main_module.create_app(Settings(openai_api_key="test-key"))

    with TestClient(app):
        assert lifespan_calls == ["schema", "nats connected", "ingestion started"]
        assert isinstance(app.state.agent_factory, AgentFactory)

    assert lifespan_calls[3:] == ["ingestion stopped", "nats closed"]
