import asyncio
import json
import sys
from pathlib import Path

import pytest

sys.path.append(str(Path(__file__).resolve().parents[1]))

from chat.search_client import AgentSearchClient


@pytest.mark.asyncio
async def test_search_client_collects_file_hits_from_ack_and_reply_flow() -> None:
    published: list[tuple[str, bytes]] = []
    ack_messages = [
        type(
            "Msg",
            (),
            {
                "data": json.dumps(
                    {
                        "requestId": "req-1",
                        "replyId": "reply-1",
                        "ack": True,
                        "types": ["files"],
                    }
                ).encode("utf-8")
            },
        )(),
    ]
    reply_messages = [
        type(
            "Msg",
            (),
            {
                "data": json.dumps(
                    {
                        "requestId": "req-1",
                        "replyId": "reply-1",
                        "type": "files",
                        "reply": {"providerId": "space-a", "path": "docs/spec.md"},
                        "last": False,
                    }
                ).encode("utf-8")
            },
        )(),
        type(
            "Msg",
            (),
            {"data": json.dumps({"requestId": "req-1", "replyId": "reply-1", "last": True}).encode("utf-8")},
        )(),
    ]

    class StubSubscription:
        def __init__(self, messages):
            self._messages = iter(messages)

        async def next_msg(self):
            return next(self._messages)

        async def unsubscribe(self) -> None:
            return None

    class StubNats:
        def __init__(self) -> None:
            self._subjects: list[str] = []

        async def subscribe(self, subject: str):
            self._subjects.append(subject)
            if subject.endswith(".ack"):
                return StubSubscription(ack_messages)
            return StubSubscription(reply_messages)

        async def publish(self, subject: str, payload: bytes) -> None:
            published.append((subject, payload))

    client = AgentSearchClient(nc=StubNats(), request_id_factory=lambda: "req-1")

    hits = await client.search_files(user_id="alice", query="spec")

    assert len(hits) == 1
    assert hits[0].provider_id == "space-a"
    assert hits[0].path == "/docs/spec.md"
    assert json.loads(published[0][1].decode("utf-8")) == {
        "requestId": "req-1",
        "userId": "alice",
        "query": "spec",
        "types": ["files"],
    }


@pytest.mark.asyncio
async def test_search_client_ignores_non_file_replies_and_errors_cleanly() -> None:
    class StubSubscription:
        def __init__(self, messages):
            self._messages = iter(messages)

        async def next_msg(self):
            return next(self._messages)

        async def unsubscribe(self) -> None:
            return None

    class StubNats:
        async def subscribe(self, subject: str):
            if subject.endswith(".ack"):
                return StubSubscription(
                    [type("Msg", (), {"data": b'{"requestId":"req-1","replyId":"reply-1","ack":true}'})()]
                )
            return StubSubscription(
                [
                    type(
                        "Msg",
                        (),
                        {
                            "data": b'{"requestId":"req-1","replyId":"reply-1","type":"other","reply":{},"last":false}'
                        },
                    )(),
                    type(
                        "Msg",
                        (),
                        {
                            "data": b'{"requestId":"req-1","replyId":"reply-1","error":"boom","last":false}'
                        },
                    )(),
                    type("Msg", (), {"data": b'{"requestId":"req-1","replyId":"reply-1","last":true}'})(),
                ]
            )

        async def publish(self, subject: str, payload: bytes) -> None:
            del subject, payload

    client = AgentSearchClient(nc=StubNats(), request_id_factory=lambda: "req-1")

    with pytest.raises(RuntimeError, match="boom"):
        await client.search_files(user_id="alice", query="spec")


@pytest.mark.asyncio
async def test_search_client_times_out_when_ack_never_arrives() -> None:
    class StubSubscription:
        async def next_msg(self):
            await asyncio.Future()

        async def unsubscribe(self) -> None:
            return None

    class StubNats:
        async def subscribe(self, subject: str):
            del subject
            return StubSubscription()

        async def publish(self, subject: str, payload: bytes) -> None:
            del subject, payload

    client = AgentSearchClient(
        nc=StubNats(),
        request_id_factory=lambda: "req-1",
        ack_timeout=0.01,
        reply_timeout=0.01,
    )

    with pytest.raises(RuntimeError, match="acknowledgement timed out"):
        await client.search_files(user_id="alice", query="spec")
