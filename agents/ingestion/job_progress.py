"""Reports the knowledge ingestion backlog to the Seraph jobs service (a Queue Job, like file-indexer's)."""

from __future__ import annotations

import time
import uuid
from io import BytesIO
from typing import Any, Dict

from fastavro import parse_schema, schemaless_writer

from ingestion.file_changed_events import EVENT_SCHEMA

JOBS_TOPIC_PATTERN = "seraph.jobs.{}"
HEARTBEAT_SECONDS = 30.0

JOB_EVENT_SCHEMA: Dict[str, Any] = {
    "type": "record",
    "name": "JobEvent",
    "namespace": "seraph.events",
    "fields": [
        {"name": "event", "type": "Event"},
        {"name": "key", "type": "string"},
        {"name": "description", "type": "string"},
        {"name": "statusMessage", "type": "string"},
        {"name": "properties", "type": {"type": "map", "values": "string"}},
        {"name": "state", "type": "string", "default": ""},
        {"name": "done", "type": "long", "default": 0},
        {"name": "total", "type": "long", "default": -1},
        {"name": "pending", "type": "long", "default": -1},
    ],
}
PARSED_JOB_EVENT_SCHEMA = parse_schema(JOB_EVENT_SCHEMA, named_schemas={"seraph.events.Event": EVENT_SCHEMA})


class QueueJob:
    """Publishes a backlog as `seraph.jobs.<key>`: running while pending > 0, idle at 0.

    Unchanged values are not resent, except a running job, which is resent every
    HEARTBEAT_SECONDS like the Go `messaging.Job`.
    """

    def __init__(self, nc: Any, key: str, description: str) -> None:
        self._nc = nc
        self._key = key
        self._description = description
        self._sent: tuple[str, int] | None = None
        self._last = 0.0

    async def pending(self, n: int, message: str) -> None:
        state = "running" if n > 0 else "idle"
        now = time.monotonic()
        if (state, n) == self._sent and (state != "running" or now - self._last < HEARTBEAT_SECONDS):
            return
        buffer = BytesIO()
        schemaless_writer(
            buffer,
            PARSED_JOB_EVENT_SCHEMA,
            {
                "event": {"id": str(uuid.uuid4()), "version": 1},
                "key": self._key,
                "description": self._description,
                "statusMessage": message,
                "properties": {},
                "state": state,
                "done": 0,
                "total": -1,
                "pending": n,
            },
        )
        await self._nc.publish(JOBS_TOPIC_PATTERN.format(self._key), buffer.getvalue())
        self._sent, self._last = (state, n), now
