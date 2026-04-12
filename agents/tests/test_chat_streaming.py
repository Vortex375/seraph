from fastapi.testclient import TestClient
import asyncio
import importlib
from typing import Any, cast
import pytest
import sys
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parents[1]))

from app.main import create_app


@pytest.mark.asyncio
async def test_stream_agent_reply_formats_sse_payload(monkeypatch: pytest.MonkeyPatch) -> None:
    streaming = importlib.import_module("chat.streaming")

    class StubMessage:
        def __init__(self, payload: dict[str, object]) -> None:
            self._payload = payload

        def to_dict(self) -> dict[str, object]:
            return self._payload

    async def fake_stream_printing_messages(*, agents, coroutine_task, **kwargs):
        del agents, kwargs
        coroutine_task.close()
        yield StubMessage({"role": "assistant", "content": "hello"}), True

    monkeypatch.setattr(streaming, "stream_printing_messages", fake_stream_printing_messages)

    chunks: list[str] = []
    async for chunk in streaming.stream_agent_reply(agent=object(), user_input="Hi"):
        chunks.append(chunk)

    assert chunks == ['data: {"role": "assistant", "content": "hello"}\n\n']


@pytest.mark.asyncio
async def test_stream_agent_reply_emits_only_final_chunk_after_repeated_intermediate_chunks(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    streaming = importlib.import_module("chat.streaming")

    class StubMessage:
        def __init__(self, payload: dict[str, object]) -> None:
            self._payload = payload

        def to_dict(self) -> dict[str, object]:
            return self._payload

    async def fake_stream_printing_messages(*, agents, coroutine_task, **kwargs):
        del agents, kwargs
        coroutine_task.close()
        yield StubMessage({"id": "assistant-1", "role": "assistant", "content": "p"}), False
        yield StubMessage({"id": "assistant-1", "role": "assistant", "content": "po"}), False
        yield StubMessage({"id": "assistant-1", "role": "assistant", "content": "pon"}), False
        yield StubMessage({"id": "assistant-1", "role": "assistant", "content": "pong"}), True

    monkeypatch.setattr(streaming, "stream_printing_messages", fake_stream_printing_messages)

    chunks: list[str] = []
    async for chunk in streaming.stream_agent_reply(agent=object(), user_input="say pong"):
        chunks.append(chunk)

    assert chunks == ['data: {"id": "assistant-1", "role": "assistant", "content": "pong"}\n\n']


@pytest.mark.asyncio
async def test_message_stream_returns_sse_payload(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()
    recorded: dict[str, Any] = {}

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
            if user_id != "alice" or session_id != "session-1":
                return None
            return StubSession(session_id, user_id, "Inbox")

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent
        yield f'data: {{"content": "{user_input}"}}\n\n'

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
            assert user_id == "alice"
            assert session_id == "session-1"
            return object()

    class StubPendingTurn:
        id = "turn-1"
        message = "hello"

    async def fake_claim_pending_turn(*, db: object, session_id: str, user_id: str):
        recorded["db"] = db
        recorded["session_id"] = session_id
        recorded["user_id"] = user_id
        return StubPendingTurn()

    async def fake_consume_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["consumed_db"] = db
        recorded["consumed_turn"] = pending_turn

    async def fake_stream_pending_turn(*, db: object, session_id: str, agent: object, pending_turn: StubPendingTurn):
        recorded["stream_db"] = db
        recorded["stream_session_id"] = session_id
        recorded["stream_pending_turn"] = pending_turn
        recorded["stream_user_input"] = pending_turn.message
        assert "consumed_turn" not in recorded
        yield f'data: {{"content": "{pending_turn.message}"}}\n\n'
        await fake_consume_pending_turn(db=db, pending_turn=pending_turn)

    app.state.agent_factory = StubAgentFactory()
    monkeypatch.setattr("api.chat.SessionService", StubSessionService)
    monkeypatch.setattr("api.chat._claim_pending_turn", fake_claim_pending_turn)
    monkeypatch.setattr("api.chat._stream_pending_turn", fake_stream_pending_turn)

    with TestClient(app) as client:
        with client.stream(
            "GET",
            "/api/v1/chat/sessions/session-1/stream",
            headers={"X-Seraph-User": "alice"},
        ) as response:
            assert response.status_code == 200
            first_chunk = next(response.iter_text())

        assert "data:" in first_chunk
        assert "hello" in first_chunk
        assert recorded["session_id"] == "session-1"
        assert recorded["user_id"] == "alice"
        assert recorded["stream_pending_turn"].id == "turn-1"
        assert recorded["consumed_turn"].id == "turn-1"


@pytest.mark.asyncio
async def test_message_stream_returns_409_when_no_pending_turn_is_claimable(monkeypatch: pytest.MonkeyPatch) -> None:
    app = create_app()
    recorded: dict[str, Any] = {}

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

        async def get_session(self, user_id: str, session_id: str) -> StubSession | None:
            if user_id != "alice" or session_id != "session-1":
                return None
            return StubSession(session_id, user_id, "Inbox")

    async def fake_claim_pending_turn(*, db: object, session_id: str, user_id: str) -> None:
        recorded["claim_db"] = db
        recorded["claim_session_id"] = session_id
        recorded["claim_user_id"] = user_id
        raise importlib.import_module("fastapi").HTTPException(status_code=409, detail="no pending chat turn")

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
            recorded["create_user_id"] = user_id
            recorded["create_session_id"] = session_id
            return object()

    app.state.agent_factory = StubAgentFactory()
    monkeypatch.setattr("api.chat.SessionService", StubSessionService)
    monkeypatch.setattr("api.chat._claim_pending_turn", fake_claim_pending_turn)

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get(
            "/api/v1/chat/sessions/session-1/stream",
            headers={"X-Seraph-User": "alice"},
        )

    assert response.status_code == 409
    assert response.json() == {"detail": "no pending chat turn"}
    assert recorded["claim_session_id"] == "session-1"
    assert recorded["claim_user_id"] == "alice"
    assert "create_session_id" not in recorded


@pytest.mark.asyncio
async def test_message_stream_returns_500_and_unclaims_when_agent_setup_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = create_app()
    recorded: dict[str, Any] = {}

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

        async def get_session(self, user_id: str, session_id: str) -> StubSession | None:
            if user_id != "alice" or session_id != "session-1":
                return None
            return StubSession(session_id, user_id, "Inbox")

    class StubPendingTurn:
        id = "turn-1"
        message = "hello"

    async def fake_claim_pending_turn(*, db: object, session_id: str, user_id: str) -> StubPendingTurn:
        recorded["claim_db"] = db
        recorded["claim_session_id"] = session_id
        recorded["claim_user_id"] = user_id
        pending_turn = StubPendingTurn()
        recorded["claimed_turn"] = pending_turn
        return pending_turn

    async def fake_unclaim_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["unclaim_db"] = db
        recorded["unclaimed_turn"] = pending_turn

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
            recorded["create_user_id"] = user_id
            recorded["create_session_id"] = session_id
            raise RuntimeError("agent setup failed")

    app.state.agent_factory = StubAgentFactory()
    monkeypatch.setattr("api.chat.SessionService", StubSessionService)
    monkeypatch.setattr("api.chat._claim_pending_turn", fake_claim_pending_turn)
    monkeypatch.setattr("api.chat._unclaim_pending_turn", fake_unclaim_pending_turn)

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get(
            "/api/v1/chat/sessions/session-1/stream",
            headers={"X-Seraph-User": "alice"},
        )

    assert response.status_code == 500
    assert recorded["claim_session_id"] == "session-1"
    assert recorded["claim_user_id"] == "alice"
    assert recorded["create_session_id"] == "session-1"
    assert recorded["create_user_id"] == "alice"
    assert recorded["unclaimed_turn"].id == "turn-1"
    assert recorded["unclaimed_turn"] is recorded["claimed_turn"]


@pytest.mark.asyncio
async def test_message_stream_requeues_turn_when_agent_setup_fails_across_requests(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = create_app()
    recorded: dict[str, Any] = {"claim_calls": 0, "unclaim_calls": 0}

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

        async def get_session(self, user_id: str, session_id: str) -> StubSession | None:
            if user_id != "alice" or session_id != "session-1":
                return None
            return StubSession(session_id, user_id, "Inbox")

    class StubPendingTurn:
        id = "turn-1"
        session_id = "session-1"
        user_id = "alice"
        message = "hello"

    async def fake_claim_pending_turn(*, db: object, session_id: str, user_id: str) -> StubPendingTurn:
        recorded["claim_calls"] = cast(int, recorded["claim_calls"]) + 1
        attempt = cast(int, recorded["claim_calls"])
        recorded["claim_db"] = db
        recorded["claim_session_id"] = session_id
        recorded["claim_user_id"] = user_id
        pending_turn = StubPendingTurn()
        recorded[f"claimed_turn_{attempt}"] = pending_turn
        return pending_turn

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
            attempt = cast(int, recorded["claim_calls"])
            recorded["create_user_id"] = user_id
            recorded["create_session_id"] = session_id
            if attempt == 1:
                raise RuntimeError("agent setup failed")
            return object()

    async def fake_stream_pending_turn(*, db: object, session_id: str, agent: object, pending_turn: StubPendingTurn):
        recorded["stream_db"] = db
        recorded["stream_session_id"] = session_id
        recorded["stream_agent"] = agent
        recorded["stream_user_input"] = pending_turn.message
        yield 'data: {"content": "hello"}\n\n'

    async def fake_unclaim_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["unclaim_calls"] = cast(int, recorded["unclaim_calls"]) + 1
        recorded["unclaim_db"] = db
        recorded["unclaimed_turn"] = pending_turn

    app.state.agent_factory = StubAgentFactory()
    monkeypatch.setattr("api.chat.SessionService", StubSessionService)
    monkeypatch.setattr("api.chat._claim_pending_turn", fake_claim_pending_turn)
    monkeypatch.setattr("api.chat._stream_pending_turn", fake_stream_pending_turn)
    monkeypatch.setattr("api.chat._unclaim_pending_turn", fake_unclaim_pending_turn)

    with TestClient(app, raise_server_exceptions=False) as client:
        failed_response = client.get(
            "/api/v1/chat/sessions/session-1/stream",
            headers={"X-Seraph-User": "alice"},
        )
        assert failed_response.status_code == 500

        with client.stream(
            "GET",
            "/api/v1/chat/sessions/session-1/stream",
            headers={"X-Seraph-User": "alice"},
        ) as response:
            assert response.status_code == 200
            first_chunk = next(response.iter_text())

    assert first_chunk == 'data: {"content": "hello"}\n\n'
    assert recorded["claim_calls"] == 2
    assert recorded["unclaim_calls"] == 1
    assert recorded["claim_session_id"] == "session-1"
    assert recorded["claim_user_id"] == "alice"
    assert recorded["create_session_id"] == "session-1"
    assert recorded["create_user_id"] == "alice"
    assert recorded["stream_session_id"] == "session-1"
    assert recorded["stream_user_input"] == "hello"
    assert recorded["unclaimed_turn"] is recorded["claimed_turn_1"]


@pytest.mark.asyncio
async def test_message_stream_returns_500_and_unclaims_when_stream_fails_before_first_chunk(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = create_app()
    recorded: dict[str, Any] = {}

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

        async def get_session(self, user_id: str, session_id: str) -> StubSession | None:
            if user_id != "alice" or session_id != "session-1":
                return None
            return StubSession(session_id, user_id, "Inbox")

    class StubPendingTurn:
        id = "turn-1"
        message = "hello"

    async def fake_claim_pending_turn(*, db: object, session_id: str, user_id: str) -> StubPendingTurn:
        recorded["claim_db"] = db
        recorded["claim_session_id"] = session_id
        recorded["claim_user_id"] = user_id
        pending_turn = StubPendingTurn()
        recorded["claimed_turn"] = pending_turn
        return pending_turn

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
            recorded["create_user_id"] = user_id
            recorded["create_session_id"] = session_id
            return object()

    async def fake_stream_chat_events(*, db: object, session_id: str, agent: object, user_input: str):
        recorded["stream_db"] = db
        recorded["stream_session_id"] = session_id
        recorded["stream_agent"] = agent
        recorded["stream_user_input"] = user_input
        raise RuntimeError("stream setup failed")
        yield ""

    async def fake_unclaim_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["unclaim_db"] = db
        recorded["unclaimed_turn"] = pending_turn

    app.state.agent_factory = StubAgentFactory()
    monkeypatch.setattr("api.chat.SessionService", StubSessionService)
    monkeypatch.setattr("api.chat._claim_pending_turn", fake_claim_pending_turn)
    monkeypatch.setattr("api.chat._stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr("api.chat._unclaim_pending_turn", fake_unclaim_pending_turn)

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get(
            "/api/v1/chat/sessions/session-1/stream",
            headers={"X-Seraph-User": "alice"},
        )

    assert response.status_code == 500
    assert recorded["claim_session_id"] == "session-1"
    assert recorded["claim_user_id"] == "alice"
    assert recorded["create_session_id"] == "session-1"
    assert recorded["create_user_id"] == "alice"
    assert recorded["stream_session_id"] == "session-1"
    assert recorded["stream_user_input"] == "hello"
    assert recorded["unclaimed_turn"] is recorded["claimed_turn"]


@pytest.mark.asyncio
async def test_message_stream_returns_500_and_unclaims_when_stream_ends_before_first_chunk(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    app = create_app()
    recorded: dict[str, Any] = {}

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

        async def get_session(self, user_id: str, session_id: str) -> StubSession | None:
            if user_id != "alice" or session_id != "session-1":
                return None
            return StubSession(session_id, user_id, "Inbox")

    class StubPendingTurn:
        id = "turn-1"
        message = "hello"

    async def fake_claim_pending_turn(*, db: object, session_id: str, user_id: str) -> StubPendingTurn:
        recorded["claim_db"] = db
        recorded["claim_session_id"] = session_id
        recorded["claim_user_id"] = user_id
        pending_turn = StubPendingTurn()
        recorded["claimed_turn"] = pending_turn
        return pending_turn

    class StubAgentFactory:
        def create(self, user_id: str, session_id: str) -> object:
            recorded["create_user_id"] = user_id
            recorded["create_session_id"] = session_id
            return object()

    async def fake_stream_chat_events(*, db: object, session_id: str, agent: object, user_input: str):
        recorded["stream_db"] = db
        recorded["stream_session_id"] = session_id
        recorded["stream_agent"] = agent
        recorded["stream_user_input"] = user_input
        if False:
            yield ""

    async def fake_consume_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["consumed_db"] = db
        recorded["consumed_turn"] = pending_turn

    async def fake_unclaim_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["unclaim_db"] = db
        recorded["unclaimed_turn"] = pending_turn

    app.state.agent_factory = StubAgentFactory()
    monkeypatch.setattr("api.chat.SessionService", StubSessionService)
    monkeypatch.setattr("api.chat._claim_pending_turn", fake_claim_pending_turn)
    monkeypatch.setattr("api.chat._stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr("api.chat._consume_pending_turn", fake_consume_pending_turn)
    monkeypatch.setattr("api.chat._unclaim_pending_turn", fake_unclaim_pending_turn)

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get(
            "/api/v1/chat/sessions/session-1/stream",
            headers={"X-Seraph-User": "alice"},
        )

    assert response.status_code == 500
    assert response.json() == {"detail": "chat stream produced no events"}
    assert recorded["claim_session_id"] == "session-1"
    assert recorded["claim_user_id"] == "alice"
    assert recorded["create_session_id"] == "session-1"
    assert recorded["create_user_id"] == "alice"
    assert recorded["stream_session_id"] == "session-1"
    assert recorded["stream_user_input"] == "hello"
    assert recorded["unclaimed_turn"] is recorded["claimed_turn"]
    assert "consumed_turn" not in recorded


@pytest.mark.asyncio
async def test_claim_pending_turn_returns_oldest_unclaimed_turn() -> None:
    chat_module = importlib.import_module("api.chat")

    class StubSessionLockResult:
        def __init__(self, row: tuple[str] | None) -> None:
            self._row = row

        def first(self) -> tuple[str] | None:
            return self._row

    class StubSelectResult:
        def __init__(self, row: tuple[str, str] | None) -> None:
            self._row = row

        def first(self) -> tuple[str, str] | None:
            return self._row

    class StubUpdateResult:
        def __init__(self, row: tuple[str, str] | None) -> None:
            self._row = row

        def first(self) -> tuple[str, str] | None:
            return self._row

    class StubDb:
        def __init__(self) -> None:
            self.executed: list[object] = []
            self.session_lock_rows = [("session-1",), ("session-1",)]
            self.existing_claim_rows = [None, None]
            self.select_rows = [("turn-1", "first"), None]
            self.update_rows = [("turn-1", "first")]
            self.commits = 0
            self.rollbacks = 0

        async def execute(self, statement: object) -> StubSessionLockResult | StubSelectResult | StubUpdateResult:
            self.executed.append(statement)
            statement_text = str(statement)
            if "FROM chat_sessions" in statement_text:
                return StubSessionLockResult(self.session_lock_rows.pop(0))
            if "pending_chat_turns.claimed IS true" in statement_text:
                return StubSelectResult(self.existing_claim_rows.pop(0))
            if "SELECT pending_chat_turns.id" in statement_text:
                return StubSelectResult(self.select_rows.pop(0))
            return StubUpdateResult(self.update_rows.pop(0) if self.update_rows else None)

        async def commit(self) -> None:
            self.commits += 1

        async def rollback(self) -> None:
            self.rollbacks += 1

    db = StubDb()
    claimed = await chat_module._claim_pending_turn(db=db, session_id="session-1", user_id="alice")

    assert claimed.id == "turn-1"
    assert claimed.message == "first"
    assert claimed.claimed_at is not None
    assert db.commits == 1
    assert db.rollbacks == 0
    session_lock_statement = db.executed[0]
    assert "FROM chat_sessions" in str(session_lock_statement)
    assert getattr(session_lock_statement, "_for_update_arg").skip_locked is True
    select_statement = db.executed[2]
    assert getattr(select_statement, "_for_update_arg").skip_locked is True

    with pytest.raises(Exception):
        await chat_module._claim_pending_turn(db=db, session_id="session-1", user_id="alice")

    assert db.rollbacks == 1


@pytest.mark.asyncio
async def test_claim_pending_turn_rejects_session_with_existing_claimed_turn() -> None:
    chat_module = importlib.import_module("api.chat")

    class StubSessionLockResult:
        def __init__(self, row: tuple[str] | None) -> None:
            self._row = row

        def first(self) -> tuple[str] | None:
            return self._row

    class StubSelectResult:
        def __init__(self, row: tuple[str, str] | None) -> None:
            self._row = row

        def first(self) -> tuple[str, str] | None:
            return self._row

    class StubUpdateResult:
        def first(self) -> tuple[str, str] | None:
            return None

    class StubDb:
        def __init__(self) -> None:
            self.executed: list[object] = []
            self.commits = 0
            self.rollbacks = 0

        async def execute(self, statement: object) -> StubSessionLockResult | StubSelectResult | StubUpdateResult:
            self.executed.append(statement)
            statement_text = str(statement).lower()
            if "from chat_sessions" in statement_text:
                return StubSessionLockResult(("session-1",))
            if "pending_chat_turns.claimed is true" in statement_text:
                return StubSelectResult(("turn-claimed", "claimed"))
            if "select pending_chat_turns.id" in statement_text:
                return StubSelectResult(("turn-2", "second"))
            return StubUpdateResult()

        async def commit(self) -> None:
            self.commits += 1

        async def rollback(self) -> None:
            self.rollbacks += 1

    db = StubDb()

    with pytest.raises(Exception):
        await chat_module._claim_pending_turn(db=db, session_id="session-1", user_id="alice")

    assert db.commits == 0
    assert len(db.executed) == 2
    assert "from chat_sessions" in str(db.executed[0]).lower()
    assert "pending_chat_turns.claimed is true" in str(db.executed[1]).lower()
    assert db.rollbacks == 1


@pytest.mark.asyncio
async def test_stream_pending_turn_unclaims_when_stream_fails_before_first_chunk() -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"consume_calls": 0, "unclaim_calls": 0}

    class StubPendingTurn:
        id = "turn-1"
        message = "hello"

    async def fake_stream_chat_events(*, db: object, session_id: str, agent: object, user_input: str):
        recorded["stream_db"] = db
        recorded["session_id"] = session_id
        recorded["agent"] = agent
        recorded["user_input"] = user_input
        if False:
            yield ""
        raise RuntimeError("stream setup failed")

    async def fake_consume_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["consume_calls"] = cast(int, recorded["consume_calls"]) + 1
        recorded["consumed_db"] = db
        recorded["consumed_turn"] = pending_turn

    async def fake_unclaim_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["unclaim_calls"] = cast(int, recorded["unclaim_calls"]) + 1
        recorded["unclaimed_db"] = db
        recorded["unclaimed_turn"] = pending_turn

    db = object()
    pending_turn = StubPendingTurn()
    monkeypatch = pytest.MonkeyPatch()
    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_consume_pending_turn", fake_consume_pending_turn)
    monkeypatch.setattr(chat_module, "_unclaim_pending_turn", fake_unclaim_pending_turn)

    try:
        with pytest.raises(RuntimeError, match="stream setup failed"):
            async for _chunk in chat_module._stream_pending_turn(
                db=db,
                session_id="session-1",
                agent=object(),
                pending_turn=pending_turn,
            ):
                pass
    finally:
        monkeypatch.undo()

    assert recorded["user_input"] == "hello"
    assert recorded["consume_calls"] == 0
    assert recorded["unclaim_calls"] == 1
    assert recorded["unclaimed_db"] is db
    assert recorded["unclaimed_turn"] is pending_turn


@pytest.mark.asyncio
async def test_stream_pending_turn_unclaims_when_cancelled_before_first_chunk() -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"consume_calls": 0, "unclaim_calls": 0}

    class StubPendingTurn:
        id = "turn-1"
        message = "hello"

    async def fake_stream_chat_events(*, db: object, session_id: str, agent: object, user_input: str):
        recorded["stream_db"] = db
        recorded["session_id"] = session_id
        recorded["agent"] = agent
        recorded["user_input"] = user_input
        if False:
            yield ""
        raise asyncio.CancelledError()

    async def fake_consume_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["consume_calls"] = cast(int, recorded["consume_calls"]) + 1
        recorded["consumed_db"] = db
        recorded["consumed_turn"] = pending_turn

    async def fake_unclaim_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["unclaim_calls"] = cast(int, recorded["unclaim_calls"]) + 1
        recorded["unclaimed_db"] = db
        recorded["unclaimed_turn"] = pending_turn

    db = object()
    pending_turn = StubPendingTurn()
    monkeypatch = pytest.MonkeyPatch()
    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_consume_pending_turn", fake_consume_pending_turn)
    monkeypatch.setattr(chat_module, "_unclaim_pending_turn", fake_unclaim_pending_turn)

    try:
        with pytest.raises(asyncio.CancelledError):
            async for _chunk in chat_module._stream_pending_turn(
                db=db,
                session_id="session-1",
                agent=object(),
                pending_turn=pending_turn,
            ):
                pass
    finally:
        monkeypatch.undo()

    assert recorded["user_input"] == "hello"
    assert recorded["consume_calls"] == 0
    assert recorded["unclaim_calls"] == 1
    assert recorded["unclaimed_db"] is db
    assert recorded["unclaimed_turn"] is pending_turn


@pytest.mark.asyncio
async def test_stream_pending_turn_consumes_when_closed_at_first_yield_boundary() -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"consume_calls": 0, "unclaim_calls": 0}

    class StubPendingTurn:
        id = "turn-1"
        session_id = "session-1"
        user_id = "alice"
        message = "hello"

    async def fake_stream_chat_events(*, db: object, session_id: str, agent: object, user_input: str):
        recorded["stream_db"] = db
        recorded["session_id"] = session_id
        recorded["agent"] = agent
        recorded["user_input"] = user_input
        yield 'data: {"content": "hello"}\n\n'

    async def fake_consume_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["consume_calls"] = cast(int, recorded["consume_calls"]) + 1
        recorded["consumed_db"] = db
        recorded["consumed_turn"] = pending_turn

    async def fake_unclaim_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["unclaim_calls"] = cast(int, recorded["unclaim_calls"]) + 1
        recorded["unclaimed_db"] = db
        recorded["unclaimed_turn"] = pending_turn

    db = object()
    pending_turn = StubPendingTurn()
    stream = chat_module._stream_pending_turn(db=db, session_id="session-1", agent=object(), pending_turn=pending_turn)
    monkeypatch = pytest.MonkeyPatch()
    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_consume_pending_turn", fake_consume_pending_turn)
    monkeypatch.setattr(chat_module, "_unclaim_pending_turn", fake_unclaim_pending_turn)

    try:
        first_chunk = await stream.__anext__()
        assert first_chunk == 'data: {"content": "hello"}\n\n'
        await stream.aclose()
    finally:
        monkeypatch.undo()

    assert recorded["user_input"] == "hello"
    assert recorded["consume_calls"] == 1
    assert recorded["consumed_db"] is db
    assert recorded["consumed_turn"] is pending_turn
    assert recorded["unclaim_calls"] == 0


@pytest.mark.asyncio
async def test_stream_pending_turn_consumes_after_stream_starts_then_fails() -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"consume_calls": 0, "unclaim_calls": 0}

    class StubPendingTurn:
        id = "turn-1"
        message = "hello"

    async def fake_stream_chat_events(*, db: object, session_id: str, agent: object, user_input: str):
        recorded["stream_db"] = db
        recorded["session_id"] = session_id
        recorded["agent"] = agent
        recorded["user_input"] = user_input
        yield 'data: {"content": "hello"}\n\n'
        raise RuntimeError("stream failed")

    async def fake_consume_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["consume_calls"] = cast(int, recorded["consume_calls"]) + 1
        recorded["consumed_db"] = db
        recorded["consumed_turn"] = pending_turn

    async def fake_unclaim_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["unclaim_calls"] = cast(int, recorded["unclaim_calls"]) + 1
        recorded["unclaimed_db"] = db
        recorded["unclaimed_turn"] = pending_turn

    db = object()
    pending_turn = StubPendingTurn()
    monkeypatch = pytest.MonkeyPatch()
    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_consume_pending_turn", fake_consume_pending_turn)
    monkeypatch.setattr(chat_module, "_unclaim_pending_turn", fake_unclaim_pending_turn)

    try:
        chunks: list[str] = []
        with pytest.raises(RuntimeError, match="stream failed"):
            async for chunk in chat_module._stream_pending_turn(
                db=db,
                session_id="session-1",
                agent=object(),
                pending_turn=pending_turn,
            ):
                chunks.append(chunk)
    finally:
        monkeypatch.undo()

    assert chunks == ['data: {"content": "hello"}\n\n']
    assert recorded["consume_calls"] == 1
    assert recorded["consumed_db"] is db
    assert recorded["consumed_turn"] is pending_turn
    assert recorded["unclaim_calls"] == 0


@pytest.mark.asyncio
async def test_stream_pending_turn_consumes_when_cancelled_after_stream_starts() -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {"consume_calls": 0, "unclaim_calls": 0}

    class StubPendingTurn:
        id = "turn-1"
        message = "hello"

    async def fake_stream_chat_events(*, db: object, session_id: str, agent: object, user_input: str):
        recorded["stream_db"] = db
        recorded["session_id"] = session_id
        recorded["agent"] = agent
        recorded["user_input"] = user_input
        yield 'data: {"content": "hello"}\n\n'
        raise asyncio.CancelledError()

    async def fake_consume_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["consume_calls"] = cast(int, recorded["consume_calls"]) + 1
        recorded["consumed_db"] = db
        recorded["consumed_turn"] = pending_turn

    async def fake_unclaim_pending_turn(*, db: object, pending_turn: StubPendingTurn) -> None:
        recorded["unclaim_calls"] = cast(int, recorded["unclaim_calls"]) + 1
        recorded["unclaimed_db"] = db
        recorded["unclaimed_turn"] = pending_turn

    db = object()
    pending_turn = StubPendingTurn()
    monkeypatch = pytest.MonkeyPatch()
    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)
    monkeypatch.setattr(chat_module, "_consume_pending_turn", fake_consume_pending_turn)
    monkeypatch.setattr(chat_module, "_unclaim_pending_turn", fake_unclaim_pending_turn)

    try:
        chunks: list[str] = []
        with pytest.raises(asyncio.CancelledError):
            async for chunk in chat_module._stream_pending_turn(
                db=db,
                session_id="session-1",
                agent=object(),
                pending_turn=pending_turn,
            ):
                chunks.append(chunk)
    finally:
        monkeypatch.undo()

    assert chunks == ['data: {"content": "hello"}\n\n']
    assert recorded["consume_calls"] == 1
    assert recorded["consumed_db"] is db
    assert recorded["consumed_turn"] is pending_turn
    assert recorded["unclaim_calls"] == 0


@pytest.mark.asyncio
async def test_claim_pending_turn_rolls_back_when_commit_fails() -> None:
    chat_module = importlib.import_module("api.chat")

    class StubResult:
        def __init__(self, row: tuple[str] | tuple[str, str] | None) -> None:
            self._row = row

        def first(self) -> tuple[str] | tuple[str, str] | None:
            return self._row

    class StubDb:
        def __init__(self) -> None:
            self.rollbacks = 0
            self.execute_calls = 0

        async def execute(self, statement: object) -> StubResult:
            del statement
            self.execute_calls += 1
            if self.execute_calls == 1:
                return StubResult(("session-1",))
            if self.execute_calls == 2:
                return StubResult(None)
            return StubResult(("turn-1", "first"))

        async def commit(self) -> None:
            raise RuntimeError("commit failed")

        async def rollback(self) -> None:
            self.rollbacks += 1

    db = StubDb()

    with pytest.raises(RuntimeError, match="commit failed"):
        await chat_module._claim_pending_turn(db=db, session_id="session-1", user_id="alice")

    assert db.rollbacks == 1


@pytest.mark.asyncio
async def test_claim_pending_turn_rolls_back_when_commit_is_cancelled() -> None:
    chat_module = importlib.import_module("api.chat")

    class StubResult:
        def __init__(self, row: tuple[str] | tuple[str, str] | None) -> None:
            self._row = row

        def first(self) -> tuple[str] | tuple[str, str] | None:
            return self._row

    class StubDb:
        def __init__(self) -> None:
            self.rollbacks = 0
            self.execute_calls = 0

        async def execute(self, statement: object) -> StubResult:
            del statement
            self.execute_calls += 1
            if self.execute_calls == 1:
                return StubResult(("session-1",))
            if self.execute_calls == 2:
                return StubResult(None)
            return StubResult(("turn-1", "first"))

        async def commit(self) -> None:
            raise asyncio.CancelledError()

        async def rollback(self) -> None:
            self.rollbacks += 1

    db = StubDb()

    with pytest.raises(asyncio.CancelledError):
        await chat_module._claim_pending_turn(db=db, session_id="session-1", user_id="alice")

    assert db.rollbacks == 1


@pytest.mark.asyncio
async def test_consume_pending_turn_rolls_back_when_commit_fails() -> None:
    chat_module = importlib.import_module("api.chat")

    class StubPendingTurn:
        id = "turn-1"
        session_id = "session-1"
        user_id = "alice"

    class StubResult:
        def first(self) -> tuple[str] | None:
            return ("session-1",)

    class StubDb:
        def __init__(self) -> None:
            self.rollbacks = 0
            self.executed: list[object] = []

        async def execute(self, statement: object) -> StubResult:
            self.executed.append(statement)
            return StubResult()

        async def commit(self) -> None:
            raise RuntimeError("commit failed")

        async def rollback(self) -> None:
            self.rollbacks += 1

    db = StubDb()

    with pytest.raises(RuntimeError, match="commit failed"):
        await chat_module._consume_pending_turn(db=db, pending_turn=StubPendingTurn())

    assert db.executed
    assert db.rollbacks == 1


@pytest.mark.asyncio
async def test_unclaim_pending_turn_rolls_back_when_commit_fails() -> None:
    chat_module = importlib.import_module("api.chat")

    class StubPendingTurn:
        id = "turn-1"
        session_id = "session-1"
        user_id = "alice"

    class StubResult:
        def first(self) -> tuple[str] | None:
            return ("session-1",)

    class StubDb:
        def __init__(self) -> None:
            self.rollbacks = 0
            self.executed: list[object] = []

        async def execute(self, statement: object) -> StubResult:
            self.executed.append(statement)
            return StubResult()

        async def commit(self) -> None:
            raise RuntimeError("commit failed")

        async def rollback(self) -> None:
            self.rollbacks += 1

    db = StubDb()

    with pytest.raises(RuntimeError, match="commit failed"):
        await chat_module._unclaim_pending_turn(db=db, pending_turn=StubPendingTurn())

    assert db.executed
    assert db.rollbacks == 1


@pytest.mark.asyncio
async def test_consume_pending_turn_rolls_back_when_commit_is_cancelled() -> None:
    chat_module = importlib.import_module("api.chat")

    class StubPendingTurn:
        id = "turn-1"
        session_id = "session-1"
        user_id = "alice"

    class StubResult:
        def first(self) -> tuple[str] | None:
            return ("session-1",)

    class StubDb:
        def __init__(self) -> None:
            self.rollbacks = 0
            self.executed: list[object] = []

        async def execute(self, statement: object) -> StubResult:
            self.executed.append(statement)
            return StubResult()

        async def commit(self) -> None:
            raise asyncio.CancelledError()

        async def rollback(self) -> None:
            self.rollbacks += 1

    db = StubDb()

    with pytest.raises(asyncio.CancelledError):
        await chat_module._consume_pending_turn(db=db, pending_turn=StubPendingTurn())

    assert db.executed
    assert db.rollbacks == 1


@pytest.mark.asyncio
async def test_unclaim_pending_turn_rolls_back_when_commit_is_cancelled() -> None:
    chat_module = importlib.import_module("api.chat")

    class StubPendingTurn:
        id = "turn-1"
        session_id = "session-1"
        user_id = "alice"

    class StubResult:
        def first(self) -> tuple[str] | None:
            return ("session-1",)

    class StubDb:
        def __init__(self) -> None:
            self.rollbacks = 0
            self.executed: list[object] = []

        async def execute(self, statement: object) -> StubResult:
            self.executed.append(statement)
            return StubResult()

        async def commit(self) -> None:
            raise asyncio.CancelledError()

        async def rollback(self) -> None:
            self.rollbacks += 1

    db = StubDb()

    with pytest.raises(asyncio.CancelledError):
        await chat_module._unclaim_pending_turn(db=db, pending_turn=StubPendingTurn())

    assert db.executed
    assert db.rollbacks == 1


@pytest.mark.asyncio
async def test_consume_pending_turn_locks_session_before_delete() -> None:
    chat_module = importlib.import_module("api.chat")

    class StubPendingTurn:
        id = "turn-1"
        session_id = "session-1"
        user_id = "alice"

    class StubResult:
        def first(self) -> tuple[str] | None:
            return ("session-1",)

    class StubDb:
        def __init__(self) -> None:
            self.executed: list[object] = []
            self.commits = 0

        async def execute(self, statement: object) -> StubResult:
            self.executed.append(statement)
            return StubResult()

        async def commit(self) -> None:
            self.commits += 1

        async def rollback(self) -> None:
            raise AssertionError("rollback should not be called")

    db = StubDb()

    await chat_module._consume_pending_turn(db=db, pending_turn=StubPendingTurn())

    assert db.commits == 1
    assert len(db.executed) == 2
    session_lock_statement = db.executed[0]
    delete_statement = db.executed[1]
    assert "FROM chat_sessions" in str(session_lock_statement)
    assert getattr(session_lock_statement, "_for_update_arg") is not None
    assert getattr(session_lock_statement, "_for_update_arg").skip_locked is False
    assert "DELETE FROM pending_chat_turns" in str(delete_statement)


@pytest.mark.asyncio
async def test_unclaim_pending_turn_locks_session_before_update() -> None:
    chat_module = importlib.import_module("api.chat")

    class StubPendingTurn:
        id = "turn-1"
        session_id = "session-1"
        user_id = "alice"

    class StubResult:
        def first(self) -> tuple[str] | None:
            return ("session-1",)

    class StubDb:
        def __init__(self) -> None:
            self.executed: list[object] = []
            self.commits = 0

        async def execute(self, statement: object) -> StubResult:
            self.executed.append(statement)
            return StubResult()

        async def commit(self) -> None:
            self.commits += 1

        async def rollback(self) -> None:
            raise AssertionError("rollback should not be called")

    db = StubDb()

    await chat_module._unclaim_pending_turn(db=db, pending_turn=StubPendingTurn())

    assert db.commits == 1
    assert len(db.executed) == 2
    session_lock_statement = db.executed[0]
    update_statement = db.executed[1]
    assert "FROM chat_sessions" in str(session_lock_statement)
    assert getattr(session_lock_statement, "_for_update_arg") is not None
    assert getattr(session_lock_statement, "_for_update_arg").skip_locked is False
    assert "UPDATE pending_chat_turns" in str(update_statement)


@pytest.mark.asyncio
async def test_stream_pending_turn_cleans_up_by_id_after_stream() -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {}

    class StubPendingTurn:
        id = "turn-1"
        session_id = "session-1"
        user_id = "alice"
        message = "hello"

    class StubResult:
        def first(self) -> tuple[str] | None:
            return ("session-1",)

    class StubDb:
        async def execute(self, statement: object) -> StubResult:
            recorded["statement"] = statement
            return StubResult()

        async def commit(self) -> None:
            recorded["committed"] = True

        async def rollback(self) -> None:
            recorded["rolled_back"] = True

    async def fake_stream_chat_events(*, db: object, session_id: str, agent: object, user_input: str):
        recorded["stream_db"] = db
        recorded["session_id"] = session_id
        recorded["agent"] = agent
        recorded["user_input"] = user_input
        yield 'data: {"content": "hello"}\n\n'

    db = StubDb()
    monkeypatch = pytest.MonkeyPatch()
    monkeypatch.setattr(chat_module, "_stream_chat_events", fake_stream_chat_events)

    try:
        chunks: list[str] = []
        async for chunk in chat_module._stream_pending_turn(
            db=db,
            session_id="session-1",
            agent=object(),
            pending_turn=StubPendingTurn(),
        ):
            chunks.append(chunk)
    finally:
        monkeypatch.undo()

    assert chunks == ['data: {"content": "hello"}\n\n']
    assert recorded["user_input"] == "hello"
    assert recorded["committed"] is True
    assert recorded["statement"] is not None


@pytest.mark.asyncio
async def test_stream_chat_events_records_sources(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, Any] = {}
    knowledge_module = importlib.import_module("knowledge.seraph_knowledge")
    document_module = importlib.import_module("agentscope.rag._document")

    class StubAgent:
        def __init__(self) -> None:
            self._knowledge_list: list[object] = []

        async def _retrieve_from_knowledge(self, msg: object) -> None:
            del msg
            self._knowledge_list = [
                knowledge_module.SeraphKnowledgeDocument(
                    id="chunk-1",
                    score=0.9,
                    provenance=knowledge_module.SeraphChunkProvenance(
                        provider_id="provider-a",
                        path="/team/spec.md",
                    ),
                    metadata=document_module.DocMetadata(
                        content={"type": "text", "text": "spec excerpt"},
                        doc_id="doc-1",
                        chunk_id=0,
                        total_chunks=1,
                    ),
                ),
                {"provider_id": "ignored", "path": "/wrong.md"},
            ]

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent, user_input
        yield (
            'data: {"id": "assistant-1", "content": "answer", '
            '"citations": [{"provider_id": "provider-b", "path": "/wrong.md"}]}\n\n'
        )

    async def fake_record_sources(
        db: object, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]
    ) -> None:
        recorded["db"] = db
        recorded["session_id"] = session_id
        recorded["assistant_message_id"] = assistant_message_id
        recorded["sources"] = sources

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_sources", fake_record_sources)

    class StubContextManager:
        async def __aenter__(self) -> object:
            recorded["isolated_db"] = object()
            return recorded["isolated_db"]

        async def __aexit__(self, exc_type, exc, tb) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    chunks: list[str] = []
    claim_db = object()
    agent = StubAgent()
    async for chunk in chat_module._stream_chat_events(
        db=claim_db, session_id="session-1", agent=agent, user_input="hello"
    ):
        chunks.append(chunk)

    assert chunks == [
        'data: {"id": "assistant-1", "content": "answer", '
        '"citations": [{"provider_id": "provider-b", "path": "/wrong.md"}]}\n\n'
    ]
    assert recorded["db"] is recorded["isolated_db"]
    assert recorded["session_id"] == "session-1"
    assert recorded["assistant_message_id"] == "assistant-1"
    assert recorded["sources"] == [{"provider_id": "provider-a", "path": "/team/spec.md"}]
    assert recorded["db"] is recorded["isolated_db"]
    assert recorded["db"] is not claim_db


@pytest.mark.asyncio
async def test_record_sources_is_idempotent_and_record_failure_recovers() -> None:
    citations = importlib.import_module("chat.citations")
    operations: list[tuple[str, Any]] = []

    class StubExisting:
        def __init__(self, provider_id: str, path: str) -> None:
            self.provider_id = provider_id
            self.path = path

    class StubScalars:
        def all(self) -> list[StubExisting]:
            return [StubExisting("provider-a", "/team/spec.md")]

    class StubResult:
        def scalars(self) -> StubScalars:
            return StubScalars()

    class StubDb:
        def __init__(self) -> None:
            self.commit_attempts = 0

        async def execute(self, statement: object) -> StubResult:
            operations.append(("execute", statement))
            return StubResult()

        def add(self, obj: object) -> None:
            operations.append(("add", obj))

        async def commit(self) -> None:
            self.commit_attempts += 1
            if self.commit_attempts == 1:
                raise RuntimeError("duplicate write")
            operations.append(("commit", self.commit_attempts))

        async def rollback(self) -> None:
            operations.append(("rollback", self.commit_attempts))

    db = StubDb()

    with pytest.raises(RuntimeError, match="duplicate write"):
        await citations.record_sources(
            db,
            session_id="session-1",
            assistant_message_id="assistant-1",
            sources=[
                {"provider_id": "provider-a", "path": "/team/spec.md"},
                {"provider_id": "provider-a", "path": "/team/spec.md"},
                {"provider_id": "provider-b", "path": "/team/other.md"},
            ],
        )

    await citations.record_failure(db, session_id="session-1", assistant_message_id="assistant-1", error="boom")

    added_sources = [obj for op, obj in operations if op == "add" and obj.__class__.__name__ == "ChatTurnSource"]
    added_failures = [obj for op, obj in operations if op == "add" and obj.__class__.__name__ == "ChatTurnFailure"]
    source = cast(Any, added_sources[0])
    failure = cast(Any, added_failures[0])

    assert len(added_sources) == 1
    assert source.provider_id == "provider-b"
    assert failure.error == "boom"
    assert [op for op, _ in operations].count("rollback") >= 2


@pytest.mark.asyncio
async def test_record_failure_rolls_back_when_commit_fails() -> None:
    citations = importlib.import_module("chat.citations")
    operations: list[str] = []

    class StubDb:
        async def rollback(self) -> None:
            operations.append("rollback")

        def add(self, obj: object) -> None:
            del obj
            operations.append("add")

        async def commit(self) -> None:
            operations.append("commit")
            raise RuntimeError("commit failed")

    db = StubDb()

    with pytest.raises(RuntimeError, match="commit failed"):
        await citations.record_failure(db, session_id="session-1", assistant_message_id="assistant-1", error="boom")

    assert operations == ["rollback", "add", "commit", "rollback"]


@pytest.mark.asyncio
async def test_record_sources_rolls_back_when_commit_is_cancelled() -> None:
    citations = importlib.import_module("chat.citations")
    operations: list[str] = []

    class StubScalars:
        def all(self) -> list[object]:
            return []

    class StubResult:
        def scalars(self) -> StubScalars:
            return StubScalars()

    class StubDb:
        async def execute(self, statement: object) -> StubResult:
            del statement
            operations.append("execute")
            return StubResult()

        def add(self, obj: object) -> None:
            del obj
            operations.append("add")

        async def commit(self) -> None:
            operations.append("commit")
            raise asyncio.CancelledError()

        async def rollback(self) -> None:
            operations.append("rollback")

    db = StubDb()

    with pytest.raises(asyncio.CancelledError):
        await citations.record_sources(
            db,
            session_id="session-1",
            assistant_message_id="assistant-1",
            sources=[{"provider_id": "provider-a", "path": "/team/spec.md"}],
        )

    assert operations == ["execute", "add", "commit", "rollback"]


@pytest.mark.asyncio
async def test_record_failure_rolls_back_when_commit_is_cancelled() -> None:
    citations = importlib.import_module("chat.citations")
    operations: list[str] = []

    class StubDb:
        async def rollback(self) -> None:
            operations.append("rollback")

        def add(self, obj: object) -> None:
            del obj
            operations.append("add")

        async def commit(self) -> None:
            operations.append("commit")
            raise asyncio.CancelledError()

    db = StubDb()

    with pytest.raises(asyncio.CancelledError):
        await citations.record_failure(db, session_id="session-1", assistant_message_id="assistant-1", error="boom")

    assert operations == ["rollback", "add", "commit", "rollback"]


@pytest.mark.asyncio
async def test_stream_chat_events_records_failures(monkeypatch: pytest.MonkeyPatch) -> None:
    chat_module = importlib.import_module("api.chat")
    recorded: dict[str, str] = {}

    async def fake_stream_agent_reply(*, agent: object, user_input: str):
        del agent, user_input
        raise RuntimeError("assistant id=assistant-9 boom")
        yield ""

    async def fake_record_failure(db: object, *, session_id: str, assistant_message_id: str, error: str) -> None:
        recorded["db_id"] = str(id(db))
        recorded["session_id"] = session_id
        recorded["assistant_message_id"] = assistant_message_id
        recorded["error"] = error

    monkeypatch.setattr(chat_module, "stream_agent_reply", fake_stream_agent_reply)
    monkeypatch.setattr(chat_module, "record_failure", fake_record_failure)

    class StubContextManager:
        async def __aenter__(self) -> object:
            db = object()
            recorded["isolated_db_id"] = str(id(db))
            return db

        async def __aexit__(self, exc_type, exc, tb) -> None:
            del exc_type, exc, tb
            return None

    monkeypatch.setattr(chat_module, "SessionLocal", lambda: StubContextManager())

    with pytest.raises(RuntimeError, match="assistant id=assistant-9 boom"):
        async for _chunk in chat_module._stream_chat_events(
            db=object(), session_id="session-1", agent=object(), user_input="hello"
        ):
            pass

    assert recorded["session_id"] == "session-1"
    assert recorded["assistant_message_id"] == "assistant-9"
    assert recorded["error"] == "assistant id=assistant-9 boom"
    assert recorded["db_id"] == recorded["isolated_db_id"]
