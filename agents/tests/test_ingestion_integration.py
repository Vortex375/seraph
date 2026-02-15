import asyncio
import json
import os
import secrets
import selectors
import subprocess
import sys
import time
from pathlib import Path
from typing import AsyncGenerator, Dict, List, Tuple

import pytest
import pytest_asyncio
from fastavro import parse_schema, schemaless_writer
from sqlalchemy import create_engine, text

sys.path.append(str(Path(__file__).resolve().parents[1]))

from agno.knowledge import Knowledge
from agno.knowledge.embedder.base import Embedder
from agno.vectordb.pgvector import PgVector, SearchType
from db import db_url
from fileprovider.client import FileProviderClient
from fileprovider.nats_client import connect_nats
from ingestion.file_changed_consumer import FileChangedIngestionConfig, FileChangedIngestionService
from ingestion.file_changed_events import EVENT_SCHEMA, FILE_CHANGED_SCHEMA


class DummyEmbedder(Embedder):
    def __init__(self, dimensions: int = 8) -> None:
        super().__init__(dimensions=dimensions)

    def _embed(self, text: str) -> List[float]:
        values = [0.0] * (self.dimensions or 8)
        for i, char in enumerate(text.encode("utf-8")):
            values[i % len(values)] += float(char % 31) / 31.0
        return values

    def get_embedding(self, text: str) -> List[float]:
        return self._embed(text)

    def get_embedding_and_usage(self, text: str) -> Tuple[List[float], Dict]:
        return self._embed(text), {}

    async def async_get_embedding(self, text: str) -> List[float]:
        return self._embed(text)

    async def async_get_embedding_and_usage(self, text: str) -> Tuple[List[float], Dict]:
        return self._embed(text), {}


def _read_line_with_timeout(proc: subprocess.Popen, timeout: float) -> str:
    if proc.stdout is None:
        raise RuntimeError("missing stdout for testserver")

    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = max(deadline - time.monotonic(), 0.0)
        events = selector.select(timeout=remaining)
        if not events:
            continue
        line = proc.stdout.readline()
        if line:
            return line.strip()
        break

    stderr = ""
    if proc.stderr is not None:
        stderr = proc.stderr.read()
    raise RuntimeError(f"testserver did not start: {stderr}")


@pytest_asyncio.fixture
async def testserver_info() -> AsyncGenerator[Dict[str, str], None]:
    repo_root = Path(__file__).resolve().parents[2]
    server_dir = repo_root / "file-provider"

    proc = subprocess.Popen(
        ["go", "run", "./cmd/fileprovider-testserver"],
        cwd=server_dir,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    try:
        line = _read_line_with_timeout(proc, timeout=15.0)
        info = json.loads(line)
        yield info
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5.0)


@pytest_asyncio.fixture
async def nats_client(testserver_info: Dict[str, str]) -> AsyncGenerator:
    nc = await connect_nats(url=testserver_info["nats_url"])
    try:
        yield nc
    finally:
        await nc.close()


def _can_connect_db() -> bool:
    try:
        engine = create_engine(db_url)
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        return False


def _encode_file_changed_event(payload: Dict[str, object]) -> bytes:
    named = {"seraph.events.Event": EVENT_SCHEMA}
    schema = parse_schema(FILE_CHANGED_SCHEMA, named_schemas=named)
    from io import BytesIO

    bio = BytesIO()
    schemaless_writer(bio, schema, payload)
    return bio.getvalue()


async def _wait_for_rows(engine, table_name: str, metadata: Dict[str, str], timeout: float) -> List[Dict]:
    deadline = time.monotonic() + timeout
    meta_json = json.dumps(metadata)
    query = text(f"SELECT content, meta_data FROM ai.{table_name} WHERE meta_data @> CAST(:meta AS jsonb)")
    while time.monotonic() < deadline:
        with engine.connect() as conn:
            result = conn.execute(query, {"meta": meta_json}).mappings().all()
        if result:
            return list(result)
        await asyncio.sleep(0.25)
    return []


async def _wait_for_rows_matching(
    engine,
    table_name: str,
    metadata: Dict[str, str],
    timeout: float,
    predicate,
) -> List[Dict]:
    deadline = time.monotonic() + timeout
    meta_json = json.dumps(metadata)
    query = text(f"SELECT content, meta_data FROM ai.{table_name} WHERE meta_data @> CAST(:meta AS jsonb)")
    while time.monotonic() < deadline:
        with engine.connect() as conn:
            result = conn.execute(query, {"meta": meta_json}).mappings().all()
        rows = list(result)
        if rows and predicate(rows):
            return rows
        await asyncio.sleep(0.25)
    return []


async def _wait_for_no_rows(engine, table_name: str, metadata: Dict[str, str], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    meta_json = json.dumps(metadata)
    query = text(f"SELECT 1 FROM ai.{table_name} WHERE meta_data @> CAST(:meta AS jsonb) LIMIT 1")
    while time.monotonic() < deadline:
        with engine.connect() as conn:
            result = conn.execute(query, {"meta": meta_json}).fetchone()
        if result is None:
            return
        await asyncio.sleep(0.25)
    raise AssertionError("Expected no rows, but rows still present")


@pytest.mark.asyncio
async def test_ingestion_create_update_delete(nats_client, testserver_info: Dict[str, str], monkeypatch):
    if not _can_connect_db():
        pytest.skip("Postgres not available for pgvector integration test")

    monkeypatch.setenv("NATS_URL", testserver_info["nats_url"])

    engine = create_engine(db_url)
    table_name = f"user_documents_kb_test_{secrets.token_hex(4)}"

    knowledge = Knowledge(
        name="Test User Documents",
        vector_db=PgVector(
            db_url=db_url,
            table_name=table_name,
            search_type=SearchType.hybrid,
            embedder=DummyEmbedder(dimensions=8),
        ),
        max_results=10,
    )

    config = FileChangedIngestionConfig(
        enabled=True,
        max_file_bytes=5 * 1024 * 1024,
        pull_batch=5,
        fetch_timeout=0.5,
        ack_wait=5.0,
        consumer_name=None,
        parallelism=1,
    )
    ingestion_service = FileChangedIngestionService(config, knowledge=knowledge)

    js = nats_client.jetstream()
    try:
        await js.add_stream(name="SERAPH_FILE_CHANGED", subjects=["seraph.file.*.changed"])
    except Exception as exc:
        pytest.skip(f"JetStream not available: {exc}")

    provider_id = testserver_info["provider_id"]
    file_id = f"file-{secrets.token_hex(4)}"
    file_path = "test_ingestion.txt"
    first_payload = b"Hello from ingestion"

    client = FileProviderClient(provider_id, nats_client)
    try:
        file_handle = await client.open_file(file_path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o644)
        await file_handle.write(first_payload)
        await file_handle.close()

        await ingestion_service.start()

        created_event = {
            "event": {"id": secrets.token_hex(6), "version": 1},
            "fileId": file_id,
            "providerId": provider_id,
            "change": "created",
            "path": file_path,
            "size": len(first_payload),
            "mode": 0,
            "modTime": int(time.time()),
            "isDir": False,
            "mime": "text/plain",
        }
        payload = _encode_file_changed_event(created_event)
        await js.publish(f"seraph.file.{file_id}.changed", payload)

        rows = await _wait_for_rows_matching(
            engine,
            table_name,
            {"file_id": file_id, "provider_id": provider_id},
            timeout=10.0,
            predicate=lambda items: any("Hello from ingestion" in row["content"] for row in items),
        )
        assert rows
        assert any("Hello from ingestion" in row["content"] for row in rows)
        assert all(row["meta_data"]["path"] == file_path for row in rows)

        updated_payload = b"Updated ingestion content"
        file_handle = await client.open_file(file_path, os.O_TRUNC | os.O_WRONLY, 0o644)
        await file_handle.write(updated_payload)
        await file_handle.close()

        updated_event = {
            "event": {"id": secrets.token_hex(6), "version": 1},
            "fileId": file_id,
            "providerId": provider_id,
            "change": "changed",
            "path": file_path,
            "size": len(updated_payload),
            "mode": 0,
            "modTime": int(time.time()),
            "isDir": False,
            "mime": "text/plain",
        }
        payload = _encode_file_changed_event(updated_event)
        await js.publish(f"seraph.file.{file_id}.changed", payload)

        rows = await _wait_for_rows_matching(
            engine,
            table_name,
            {"file_id": file_id, "provider_id": provider_id},
            timeout=10.0,
            predicate=lambda items: any("Updated ingestion content" in row["content"] for row in items),
        )
        assert any("Updated ingestion content" in row["content"] for row in rows)

        deleted_event = {
            "event": {"id": secrets.token_hex(6), "version": 1},
            "fileId": file_id,
            "providerId": provider_id,
            "change": "deleted",
            "path": file_path,
            "size": len(updated_payload),
            "mode": 0,
            "modTime": int(time.time()),
            "isDir": False,
            "mime": "text/plain",
        }
        payload = _encode_file_changed_event(deleted_event)
        await js.publish(f"seraph.file.{file_id}.changed", payload)

        await _wait_for_no_rows(
            engine,
            table_name,
            {"file_id": file_id, "provider_id": provider_id},
            timeout=10.0,
        )
    finally:
        await ingestion_service.stop()
        await client.close()
        with engine.connect() as conn:
            conn.execute(text(f"DROP TABLE IF EXISTS ai.{table_name}"))
