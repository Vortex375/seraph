from io import BytesIO
from typing import Any, cast

import pytest
from fastavro import schemaless_reader

from ingestion import job_progress
from ingestion.job_progress import PARSED_JOB_EVENT_SCHEMA, QueueJob


class RecordingNats:
    def __init__(self) -> None:
        self.published: list[tuple[str, dict[str, Any]]] = []

    async def publish(self, subject: str, payload: bytes) -> None:
        event = schemaless_reader(BytesIO(payload), PARSED_JOB_EVENT_SCHEMA, None)
        self.published.append((subject, cast(dict[str, Any], event)))


@pytest.mark.asyncio
async def test_queue_job_publishes_backlog_and_skips_unchanged_values(monkeypatch) -> None:
    clock = [100.0]
    monkeypatch.setattr(job_progress.time, "monotonic", lambda: clock[0])
    nc = RecordingNats()
    job = QueueJob(nc, "knowledge-indexer", "Indexing knowledge")

    await job.pending(3, "3 remaining")
    await job.pending(3, "3 remaining")  # unchanged, within heartbeat
    clock[0] += 31
    await job.pending(3, "3 remaining")  # heartbeat for a running job
    await job.pending(0, "up to date")
    clock[0] += 31
    await job.pending(0, "up to date")  # idle is never resent

    assert [(subject, ev["state"], ev["pending"]) for subject, ev in nc.published] == [
        ("seraph.jobs.knowledge-indexer", "running", 3),
        ("seraph.jobs.knowledge-indexer", "running", 3),
        ("seraph.jobs.knowledge-indexer", "idle", 0),
    ]
    first = nc.published[0][1]
    assert first["key"] == "knowledge-indexer"
    assert first["description"] == "Indexing knowledge"
    assert first["statusMessage"] == "3 remaining"
    assert first["total"] == -1
