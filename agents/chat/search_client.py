from __future__ import annotations

import json
import asyncio
from dataclasses import dataclass
from typing import Any, Callable
from uuid import uuid4


SEARCH_REQUEST_TOPIC = "seraph.search"
SEARCH_ACK_TOPIC_PATTERN = "seraph.search.%s.ack"
SEARCH_REPLY_TOPIC_PATTERN = "seraph.search.%s.reply"
SEARCH_TYPE_FILES = "files"


@dataclass(frozen=True)
class SearchFileHit:
    provider_id: str
    path: str


class AgentSearchClient:
    def __init__(
        self,
        nc: Any,
        request_id_factory: Callable[[], str] | None = None,
        ack_timeout: float = 5.0,
        reply_timeout: float = 30.0,
    ) -> None:
        self._nc = nc
        self._request_id_factory = request_id_factory or (lambda: str(uuid4()))
        self._ack_timeout = ack_timeout
        self._reply_timeout = reply_timeout

    async def search_files(self, *, user_id: str, query: str) -> list[SearchFileHit]:
        request_id = self._request_id_factory()
        ack_sub = await self._nc.subscribe(SEARCH_ACK_TOPIC_PATTERN % request_id)
        reply_sub = await self._nc.subscribe(SEARCH_REPLY_TOPIC_PATTERN % request_id)
        try:
            payload = {
                "requestId": request_id,
                "userId": user_id,
                "query": query,
                "types": [SEARCH_TYPE_FILES],
            }
            await self._nc.publish(SEARCH_REQUEST_TOPIC, json.dumps(payload).encode("utf-8"))

            try:
                await asyncio.wait_for(ack_sub.next_msg(), timeout=self._ack_timeout)
            except TimeoutError as exc:
                raise RuntimeError("file search acknowledgement timed out") from exc

            hits: list[SearchFileHit] = []
            while True:
                try:
                    msg = await asyncio.wait_for(reply_sub.next_msg(), timeout=self._reply_timeout)
                except TimeoutError as exc:
                    raise RuntimeError("file search reply timed out") from exc
                reply = json.loads(msg.data.decode("utf-8"))
                if reply.get("error"):
                    raise RuntimeError(str(reply["error"]))
                if reply.get("last"):
                    return hits
                if reply.get("type") != SEARCH_TYPE_FILES:
                    continue
                data = reply.get("reply", {})
                provider_id = str(data.get("providerId", "")).strip()
                path_value = str(data.get("path", "")).strip()
                if not provider_id or not path_value:
                    continue
                path = "/" + path_value.lstrip("/")
                hits.append(SearchFileHit(provider_id=provider_id, path=path))
        finally:
            await ack_sub.unsubscribe()
            await reply_sub.unsubscribe()
