"""Docker-based integration tests for the agents chat API.

These tests exercise the real API deployed through ``docker-compose.dev.yml``.
They require the ``agents-api`` container (and its dependencies) to be running.

Environment variables:

* ``AGENTS_API_URL`` - Base URL of the running agents API
  (default: ``http://localhost:8000``).
* ``OPENAI_API_KEY`` - Required for the end-to-end agent response test.
  When missing, that test is skipped.

Run with::

    uv run pytest tests/test_chat_docker_integration.py -v
"""

from __future__ import annotations

import json
import os
import uuid
from collections.abc import Generator
from urllib.parse import urljoin

import pytest
import requests

AGENTS_API_URL = os.getenv("AGENTS_API_URL", "http://localhost:8000")
CHAT_API_URL = urljoin(AGENTS_API_URL.rstrip("/") + "/", "api/v1/chat")
HEALTHZ_URL = urljoin(AGENTS_API_URL.rstrip("/") + "/", "healthz")


def _api_is_reachable() -> bool:
    try:
        response = requests.get(HEALTHZ_URL, timeout=5)
        return response.status_code == 200 and response.json().get("status") == "ok"
    except Exception:  # noqa: BLE001
        return False


pytestmark = pytest.mark.skipif(
    not _api_is_reachable(),
    reason=f"Agents API is not reachable at {AGENTS_API_URL}",
)


@pytest.fixture
def api_client() -> requests.Session:
    return requests.Session()


@pytest.fixture
def user_id() -> str:
    return f"docker-integration-{uuid.uuid4()}"


@pytest.fixture
def session(api_client: requests.Session, user_id: str) -> Generator[dict, None, None]:
    """Create a chat session and clean it up after the test."""
    headers = {"X-Seraph-User": user_id}
    response = api_client.post(
        f"{CHAT_API_URL}/sessions",
        json={"title": "Docker integration test session"},
        headers=headers,
    )
    assert response.status_code == 201, response.text
    session = response.json()
    yield session
    api_client.delete(
        f"{CHAT_API_URL}/sessions/{session['id']}",
        headers=headers,
    )


def test_healthz() -> None:
    response = requests.get(HEALTHZ_URL, timeout=5)
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_create_list_and_delete_session(api_client: requests.Session, user_id: str) -> None:
    headers = {"X-Seraph-User": user_id}

    create_resp = api_client.post(
        f"{CHAT_API_URL}/sessions",
        json={"title": "CRUD test session"},
        headers=headers,
    )
    assert create_resp.status_code == 201
    session = create_resp.json()
    session_id = session["id"]
    assert session["user_id"] == user_id
    assert session["title"] == "CRUD test session"

    list_resp = api_client.get(f"{CHAT_API_URL}/sessions", headers=headers)
    assert list_resp.status_code == 200
    session_ids = {item["id"] for item in list_resp.json()}
    assert session_id in session_ids

    delete_resp = api_client.delete(
        f"{CHAT_API_URL}/sessions/{session_id}",
        headers=headers,
    )
    assert delete_resp.status_code == 204

    list_after_delete = api_client.get(f"{CHAT_API_URL}/sessions", headers=headers)
    assert session_id not in {item["id"] for item in list_after_delete.json()}


def _parse_sse_stream(response: requests.Response) -> list[dict]:
    """Parse ``data:`` lines from an SSE stream into JSON payloads."""
    payloads: list[dict] = []
    for line in response.iter_lines(decode_unicode=True):
        if not line or not line.startswith("data:"):
            continue
        text = line[len("data:") :].strip()
        if text in ("", "[DONE]"):
            continue
        try:
            payloads.append(json.loads(text))
        except json.JSONDecodeError:
            continue
    return payloads


def test_message_stream_returns_sse_events(api_client: requests.Session, session: dict) -> None:
    """The message stream endpoint returns a valid Server-Sent Events response."""
    headers = {"X-Seraph-User": session["user_id"]}
    response = api_client.post(
        f"{CHAT_API_URL}/sessions/{session['id']}/messages/stream",
        json={"message": "Hello from the integration test"},
        headers=headers,
        stream=True,
    )
    assert response.status_code == 200
    assert "text/event-stream" in response.headers.get("content-type", "")

    payloads = _parse_sse_stream(response)
    assert payloads, "Expected at least one SSE data payload"
    assert any(payload.get("type") == "done" for payload in payloads), (
        "Expected a termination 'done' event in the stream"
    )


@pytest.mark.skipif(
    not os.getenv("OPENAI_API_KEY"),
    reason="OPENAI_API_KEY is required for an end-to-end agent response",
)
def test_agent_replies_and_messages_are_persisted(
    api_client: requests.Session,
    session: dict,
) -> None:
    """A streamed conversation produces both a user and assistant message."""
    headers = {"X-Seraph-User": session["user_id"]}
    message = "Say exactly 'pong'"

    stream_resp = api_client.post(
        f"{CHAT_API_URL}/sessions/{session['id']}/messages/stream",
        json={"message": message},
        headers=headers,
        stream=True,
    )
    assert stream_resp.status_code == 200

    payloads = _parse_sse_stream(stream_resp)
    assistant_deltas = [
        payload.get("content", "")
        for payload in payloads
        if payload.get("role") == "assistant" and payload.get("type") == "delta"
    ]
    assistant_text = "".join(assistant_deltas)
    assert assistant_text, "Expected non-empty assistant reply"

    messages_resp = api_client.get(
        f"{CHAT_API_URL}/sessions/{session['id']}/messages",
        headers=headers,
    )
    assert messages_resp.status_code == 200
    messages = messages_resp.json()
    roles = [m["role"] for m in messages]
    assert "user" in roles
    assert "assistant" in roles

    user_message = next(m for m in messages if m["role"] == "user")
    assert user_message["content"] == message

    assistant_message = next(m for m in messages if m["role"] == "assistant")
    assert assistant_message["content"] == assistant_text
    assert assistant_message.get("status") == "finished"
