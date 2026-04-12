import asyncio
import sys
from pathlib import Path

import pytest

sys.path.append(str(Path(__file__).resolve().parents[1]))


@pytest.mark.asyncio
async def test_backfill_documents_command_replays_stream_messages(monkeypatch: pytest.MonkeyPatch) -> None:
    repair = __import__("app.repair", fromlist=["placeholder"])

    processed_messages: list[str] = []

    class StubMessage:
        def __init__(self, data: bytes) -> None:
            self.data = data

        async def ack(self) -> None:
            return None

        async def nak(self) -> None:
            return None

    class StubJetStream:
        def __init__(self) -> None:
            self._messages = {
                1: StubMessage(b"first"),
                2: StubMessage(b"second"),
            }

        async def stream_info(self, stream_name: str):
            assert stream_name == "SERAPH_FILE_CHANGED"
            return type("StreamInfo", (), {"state": type("State", (), {"last_seq": 2})()})()

        async def get_msg(self, stream_name: str, seq: int):
            assert stream_name == "SERAPH_FILE_CHANGED"
            return self._messages[seq]

    class StubNatsClient:
        def __init__(self) -> None:
            self.closed = False
            self._js = StubJetStream()

        def jetstream(self):
            return self._js

        async def close(self) -> None:
            self.closed = True

    class StubIngestionService:
        async def _handle_message(self, msg) -> str:
            processed_messages.append(msg.data.decode("utf-8"))
            return "indexed"

    stub_nc = StubNatsClient()

    async def fake_connect_nats_from_env():
        return stub_nc

    monkeypatch.setattr(repair, "connect_nats_from_env", fake_connect_nats_from_env)
    monkeypatch.setattr(repair, "create_ingestion_service", lambda: StubIngestionService())

    result = await repair.backfill_documents_from_stream()

    assert result.processed == 2
    assert result.failed == 0
    assert processed_messages == ["first", "second"]
    assert stub_nc.closed is True


@pytest.mark.asyncio
async def test_backfill_documents_command_counts_processing_failures(monkeypatch: pytest.MonkeyPatch) -> None:
    repair = __import__("app.repair", fromlist=["placeholder"])

    processed_messages: list[str] = []

    class StubMessage:
        def __init__(self, data: bytes) -> None:
            self.data = data

        async def ack(self) -> None:
            return None

        async def nak(self) -> None:
            return None

    class StubJetStream:
        def __init__(self) -> None:
            self._messages = {
                1: StubMessage(b"first"),
                2: StubMessage(b"second"),
            }

        async def stream_info(self, stream_name: str):
            assert stream_name == "SERAPH_FILE_CHANGED"
            return type("StreamInfo", (), {"state": type("State", (), {"last_seq": 2})()})()

        async def get_msg(self, stream_name: str, seq: int):
            assert stream_name == "SERAPH_FILE_CHANGED"
            return self._messages[seq]

    class StubNatsClient:
        def __init__(self) -> None:
            self.closed = False
            self._js = StubJetStream()

        def jetstream(self):
            return self._js

        async def close(self) -> None:
            self.closed = True

    class StubIngestionService:
        async def _handle_message(self, msg) -> str:
            payload = msg.data.decode("utf-8")
            if payload == "second":
                raise RuntimeError("boom")
            processed_messages.append(payload)
            return "indexed"

    stub_nc = StubNatsClient()

    async def fake_connect_nats_from_env():
        return stub_nc

    monkeypatch.setattr(repair, "connect_nats_from_env", fake_connect_nats_from_env)
    monkeypatch.setattr(repair, "create_ingestion_service", lambda: StubIngestionService())

    result = await repair.backfill_documents_from_stream()

    assert result.processed == 1
    assert result.failed == 1
    assert processed_messages == ["first"]
    assert stub_nc.closed is True


@pytest.mark.asyncio
async def test_backfill_documents_command_reuses_nats_client_for_ingestion(monkeypatch: pytest.MonkeyPatch) -> None:
    repair = __import__("app.repair", fromlist=["placeholder"])

    class StubMessage:
        def __init__(self, data: bytes) -> None:
            self.data = data

    class StubJetStream:
        async def stream_info(self, stream_name: str):
            assert stream_name == "SERAPH_FILE_CHANGED"
            return type("StreamInfo", (), {"state": type("State", (), {"last_seq": 1})()})()

        async def get_msg(self, stream_name: str, seq: int):
            assert stream_name == "SERAPH_FILE_CHANGED"
            assert seq == 1
            return StubMessage(b"first")

    class StubNatsClient:
        def __init__(self) -> None:
            self.closed = False
            self._js = StubJetStream()

        def jetstream(self):
            return self._js

        async def close(self) -> None:
            self.closed = True

    class StubIngestionService:
        def __init__(self) -> None:
            self._nc = None

        async def _handle_message(self, msg) -> str:
            assert self._nc is stub_nc
            return "indexed"

    stub_nc = StubNatsClient()
    stub_service = StubIngestionService()

    async def fake_connect_nats_from_env():
        return stub_nc

    monkeypatch.setattr(repair, "connect_nats_from_env", fake_connect_nats_from_env)
    monkeypatch.setattr(repair, "create_ingestion_service", lambda: stub_service)

    result = await repair.backfill_documents_from_stream()

    assert result == repair.BackfillResult(processed=1, failed=0)
    assert stub_service._nc is stub_nc
    assert stub_nc.closed is True


@pytest.mark.asyncio
async def test_backfill_documents_command_uses_handle_message_failure_path(monkeypatch: pytest.MonkeyPatch) -> None:
    repair = __import__("app.repair", fromlist=["placeholder"])

    calls: list[str] = []

    class StubMessage:
        def __init__(self, data: bytes) -> None:
            self.data = data

        async def ack(self) -> None:
            calls.append(f"ack:{self.data.decode('utf-8')}")

        async def nak(self) -> None:
            calls.append(f"nak:{self.data.decode('utf-8')}")

    class StubJetStream:
        def __init__(self) -> None:
            self._messages = {
                1: StubMessage(b"first"),
                2: StubMessage(b"second"),
            }

        async def stream_info(self, stream_name: str):
            assert stream_name == "SERAPH_FILE_CHANGED"
            return type("StreamInfo", (), {"state": type("State", (), {"last_seq": 2})()})()

        async def get_msg(self, stream_name: str, seq: int):
            assert stream_name == "SERAPH_FILE_CHANGED"
            return self._messages[seq]

    class StubNatsClient:
        def __init__(self) -> None:
            self.closed = False
            self._js = StubJetStream()

        def jetstream(self):
            return self._js

        async def close(self) -> None:
            self.closed = True

    class StubIngestionService:
        def __init__(self) -> None:
            self._nc = None

        async def _handle_message(self, msg) -> str:
            payload = msg.data.decode("utf-8")
            calls.append(f"handle:{payload}")
            if payload == "second":
                await msg.nak()
                raise RuntimeError("boom")
            await msg.ack()
            return "indexed"

    stub_nc = StubNatsClient()

    async def fake_connect_nats_from_env():
        return stub_nc

    monkeypatch.setattr(repair, "connect_nats_from_env", fake_connect_nats_from_env)
    monkeypatch.setattr(repair, "create_ingestion_service", lambda: StubIngestionService())

    result = await repair.backfill_documents_from_stream()

    assert result.processed == 1
    assert result.failed == 1
    assert calls == ["handle:first", "ack:first", "handle:second", "nak:second"]
    assert stub_nc.closed is True


@pytest.mark.asyncio
async def test_backfill_documents_command_counts_only_successful_handle_results(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    repair = __import__("app.repair", fromlist=["placeholder"])

    class StubMessage:
        def __init__(self, data: bytes) -> None:
            self.data = data

        async def ack(self) -> None:
            return None

        async def nak(self) -> None:
            return None

    class StubJetStream:
        def __init__(self) -> None:
            self._messages = {
                1: StubMessage(b"indexed"),
                2: StubMessage(b"failed"),
                3: StubMessage(b"skipped"),
            }

        async def stream_info(self, stream_name: str):
            assert stream_name == "SERAPH_FILE_CHANGED"
            return type("StreamInfo", (), {"state": type("State", (), {"last_seq": 3})()})()

        async def get_msg(self, stream_name: str, seq: int):
            assert stream_name == "SERAPH_FILE_CHANGED"
            return self._messages[seq]

    class StubNatsClient:
        def __init__(self) -> None:
            self.closed = False
            self._js = StubJetStream()

        def jetstream(self):
            return self._js

        async def close(self) -> None:
            self.closed = True

    class StubIngestionService:
        def __init__(self) -> None:
            self._nc = None

        async def _handle_message(self, msg) -> str:
            payload = msg.data.decode("utf-8")
            if payload == "indexed":
                return "indexed"
            if payload == "skipped":
                return "skipped"
            return "failed"

    stub_nc = StubNatsClient()

    async def fake_connect_nats_from_env():
        return stub_nc

    monkeypatch.setattr(repair, "connect_nats_from_env", fake_connect_nats_from_env)
    monkeypatch.setattr(repair, "create_ingestion_service", lambda: StubIngestionService())

    result = await repair.backfill_documents_from_stream()

    assert result.processed == 1
    assert result.failed == 1
    assert stub_nc.closed is True
