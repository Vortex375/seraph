import asyncio
import json
import os
import secrets
import selectors
import subprocess
import sys
import time
from pathlib import Path
from types import SimpleNamespace
from typing import AsyncGenerator, Callable, Dict, Sequence

import pytest
import pytest_asyncio
from fastavro import parse_schema, schemaless_writer
from sqlalchemy import create_engine, text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

sys.path.append(str(Path(__file__).resolve().parents[1]))

from db import db_url
from db.session import _build_async_db_url
from documents.models import Base, DocumentChunk, IndexedDocument
from documents.repository import DocumentsRepository
from fileprovider.client import FileProviderClient
from fileprovider.nats_client import connect_nats
from ingestion.file_changed_consumer import FileChangedIngestionConfig, FileChangedIngestionService
from ingestion.file_changed_events import EVENT_SCHEMA, FILE_CHANGED_SCHEMA


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


async def _wait_for_document(
    session_factory: async_sessionmaker,
    provider_id: str,
    path: str,
    timeout: float,
    predicate: Callable[[IndexedDocument, Sequence[DocumentChunk]], bool] | None = None,
) -> tuple[IndexedDocument | None, list[DocumentChunk]]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        async with session_factory() as session:
            repo = DocumentsRepository(session)
            document, chunks = await repo.get_document_with_chunks(provider_id, path)
        if document is not None and (predicate is None or predicate(document, chunks)):
            return document, chunks
        await asyncio.sleep(0.25)
    return None, []


def _build_message(event_payload: Dict[str, object]) -> SimpleNamespace:
    async def ack() -> None:
        return None

    async def nak() -> None:
        return None

    return SimpleNamespace(data=_encode_file_changed_event(event_payload), ack=ack, nak=nak)


@pytest.mark.asyncio
async def test_handle_message_acks_terminal_skip_cases() -> None:
    config = FileChangedIngestionConfig(
        enabled=True,
        max_file_bytes=1024,
        pull_batch=1,
        fetch_timeout=0.1,
        ack_wait=1.0,
        consumer_name=None,
        parallelism=1,
        idle_backoff_base=0.0,
        idle_backoff_max=0.0,
    )
    service = FileChangedIngestionService(config)

    acked = 0
    naked = 0

    async def ack() -> None:
        nonlocal acked
        acked += 1

    async def nak() -> None:
        nonlocal naked
        naked += 1

    skipped_messages = [
        SimpleNamespace(data=b"not-avro", ack=ack, nak=nak),
        SimpleNamespace(
            data=_encode_file_changed_event(
                {
                    "event": {"id": secrets.token_hex(6), "version": 1},
                    "fileId": "file-dir",
                    "providerId": "provider-a",
                    "change": "changed",
                    "path": "/team/dir",
                    "size": 0,
                    "mode": 0,
                    "modTime": 1,
                    "isDir": True,
                    "mime": "text/plain",
                }
            ),
            ack=ack,
            nak=nak,
        ),
        SimpleNamespace(
            data=_encode_file_changed_event(
                {
                    "event": {"id": secrets.token_hex(6), "version": 1},
                    "fileId": "file-missing-provider",
                    "providerId": "",
                    "change": "changed",
                    "path": "/team/spec.txt",
                    "size": 1,
                    "mode": 0,
                    "modTime": 1,
                    "isDir": False,
                    "mime": "text/plain",
                }
            ),
            ack=ack,
            nak=nak,
        ),
    ]

    for msg in skipped_messages:
        await service._handle_message(msg)

    assert acked == 3
    assert naked == 0


@pytest.mark.asyncio
async def test_process_message_serializes_same_document_events(monkeypatch) -> None:
    config = FileChangedIngestionConfig(
        enabled=True,
        max_file_bytes=1024,
        pull_batch=2,
        fetch_timeout=0.1,
        ack_wait=1.0,
        consumer_name=None,
        parallelism=2,
        idle_backoff_base=0.0,
        idle_backoff_max=0.0,
    )
    service = FileChangedIngestionService(config)

    in_flight = 0
    max_in_flight = 0

    async def fake_process_document_event(event, normalized_mime):
        nonlocal in_flight, max_in_flight
        in_flight += 1
        max_in_flight = max(max_in_flight, in_flight)
        try:
            await asyncio.sleep(0.05)
        finally:
            in_flight -= 1

    monkeypatch.setattr(service, "_process_document_event", fake_process_document_event)

    event = {
        "event": {"id": secrets.token_hex(6), "version": 1},
        "fileId": "file-1",
        "providerId": "provider-a",
        "change": "changed",
        "path": "/team/spec.txt",
        "size": 10,
        "mode": 0,
        "modTime": 1,
        "isDir": False,
        "mime": "text/plain",
    }

    await asyncio.gather(
        service._process_message(_build_message(event)), service._process_message(_build_message(event))
    )

    assert max_in_flight == 1


@pytest.mark.asyncio
async def test_handle_message_records_failed_status_for_ingest_error() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    config = FileChangedIngestionConfig(
        enabled=True,
        max_file_bytes=1024,
        pull_batch=1,
        fetch_timeout=0.1,
        ack_wait=1.0,
        consumer_name=None,
        parallelism=1,
        idle_backoff_base=0.0,
        idle_backoff_max=0.0,
    )
    service = FileChangedIngestionService(config, session_factory=session_factory)

    async def boom(event, normalized_mime):
        raise RuntimeError("boom")

    service._ingest_file = boom  # type: ignore[method-assign]

    acked = False
    naked = False

    async def ack() -> None:
        nonlocal acked
        acked = True

    async def nak() -> None:
        nonlocal naked
        naked = True

    event = {
        "event": {"id": secrets.token_hex(6), "version": 1},
        "fileId": "file-2",
        "providerId": "provider-a",
        "change": "created",
        "path": "/team/broken.txt",
        "size": 10,
        "mode": 0,
        "modTime": 2,
        "isDir": False,
        "mime": "text/plain",
    }
    msg = SimpleNamespace(data=_encode_file_changed_event(event), ack=ack, nak=nak)

    await service._handle_message(msg)

    async with session_factory() as session:
        repo = DocumentsRepository(session)
        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/broken.txt")

    assert acked is False
    assert naked is True
    assert document is not None
    assert document.ingest_status == "failed"
    assert document.last_error == "boom"
    assert chunks == []

    await engine.dispose()


@pytest.mark.asyncio
async def test_older_failed_message_does_not_overwrite_newer_success(monkeypatch) -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    config = FileChangedIngestionConfig(
        enabled=True,
        max_file_bytes=1024,
        pull_batch=1,
        fetch_timeout=0.1,
        ack_wait=1.0,
        consumer_name=None,
        parallelism=2,
        idle_backoff_base=0.0,
        idle_backoff_max=0.0,
    )
    service = FileChangedIngestionService(config, session_factory=session_factory)

    async def fake_ingest_file(event, normalized_mime):
        if event.mod_time == 1:
            raise RuntimeError("boom")
        async with session_factory() as session:
            repo = DocumentsRepository(session)
            await repo.upsert_document(
                provider_id=event.provider_id,
                file_id=event.file_id,
                path=event.path,
                mime=normalized_mime,
                size=event.size,
                mod_time=event.mod_time,
                text="new text",
            )

    service._ingest_file = fake_ingest_file  # type: ignore[method-assign]

    failure_gate = asyncio.Event()
    original_record_ingest_failure = DocumentsRepository.record_ingest_failure

    async def delayed_record_ingest_failure(self, **kwargs):
        await failure_gate.wait()
        return await original_record_ingest_failure(self, **kwargs)

    monkeypatch.setattr(DocumentsRepository, "record_ingest_failure", delayed_record_ingest_failure)

    old_event = {
        "event": {"id": secrets.token_hex(6), "version": 1},
        "fileId": "file-4",
        "providerId": "provider-a",
        "change": "changed",
        "path": "/team/order.txt",
        "size": 10,
        "mode": 0,
        "modTime": 1,
        "isDir": False,
        "mime": "text/plain",
    }
    new_event = {
        "event": {"id": secrets.token_hex(6), "version": 1},
        "fileId": "file-4",
        "providerId": "provider-a",
        "change": "changed",
        "path": "/team/order.txt",
        "size": 10,
        "mode": 0,
        "modTime": 2,
        "isDir": False,
        "mime": "text/plain",
    }

    old_task = asyncio.create_task(service._handle_message(_build_message(old_event)))
    await asyncio.sleep(0.05)
    new_task = asyncio.create_task(service._handle_message(_build_message(new_event)))
    await asyncio.sleep(0.05)
    failure_gate.set()
    await asyncio.gather(old_task, new_task)

    async with session_factory() as session:
        repo = DocumentsRepository(session)
        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/order.txt")

    assert document is not None
    assert document.mod_time == 2
    assert document.ingest_status == "indexed"
    assert document.last_error is None
    assert any("new text" in chunk.content for chunk in chunks)

    await engine.dispose()


@pytest.mark.asyncio
async def test_wait_for_document_waits_for_updated_state() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as session:
        repo = DocumentsRepository(session)
        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-3",
            path="/team/update.txt",
            mime="text/plain",
            size=5,
            mod_time=1,
            text="old",
        )

    async def delayed_update() -> None:
        await asyncio.sleep(0.05)
        async with session_factory() as session:
            repo = DocumentsRepository(session)
            await repo.upsert_document(
                provider_id="provider-a",
                file_id="file-3",
                path="/team/update.txt",
                mime="text/plain",
                size=7,
                mod_time=2,
                text="new text",
            )

    update_task = asyncio.create_task(delayed_update())
    document, chunks = await _wait_for_document(
        session_factory,
        "provider-a",
        "/team/update.txt",
        timeout=2.0,
        predicate=lambda document, chunks: (
            document.mod_time == 2 and any("new text" in chunk.content for chunk in chunks)
        ),
    )
    await update_task

    assert document is not None
    assert document.mod_time == 2
    assert any("new text" in chunk.content for chunk in chunks)

    await engine.dispose()


async def _wait_for_no_document(
    session_factory: async_sessionmaker,
    provider_id: str,
    path: str,
    timeout: float,
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        async with session_factory() as session:
            repo = DocumentsRepository(session)
            document, _ = await repo.get_document_with_chunks(provider_id, path)
        if document is None:
            return
        await asyncio.sleep(0.25)
    raise AssertionError("Expected no document, but rows still present")


@pytest.mark.asyncio
async def test_ingestion_create_update_delete(nats_client, testserver_info: Dict[str, str], monkeypatch):
    if not _can_connect_db():
        pytest.skip("Postgres not available for pgvector integration test")

    monkeypatch.setenv("NATS_URL", testserver_info["nats_url"])

    engine = create_engine(db_url)
    async_engine = create_async_engine(_build_async_db_url(db_url))
    async_session_factory = async_sessionmaker(async_engine, expire_on_commit=False)
    async with async_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    config = FileChangedIngestionConfig(
        enabled=True,
        max_file_bytes=5 * 1024 * 1024,
        pull_batch=5,
        fetch_timeout=0.5,
        ack_wait=5.0,
        consumer_name=None,
        parallelism=1,
        idle_backoff_base=0.0,
        idle_backoff_max=0.0,
    )
    ingestion_service = FileChangedIngestionService(config)

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

        document, chunks = await _wait_for_document(
            async_session_factory,
            provider_id,
            file_path,
            timeout=10.0,
            predicate=lambda document, chunks: any("Hello from ingestion" in chunk.content for chunk in chunks),
        )
        assert document is not None
        assert document.file_id == file_id
        assert any("Hello from ingestion" in chunk.content for chunk in chunks)

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

        document, chunks = await _wait_for_document(
            async_session_factory,
            provider_id,
            file_path,
            timeout=10.0,
            predicate=lambda document, chunks: (
                document.mod_time == updated_event["modTime"]
                and any("Updated ingestion content" in chunk.content for chunk in chunks)
            ),
        )
        assert document is not None
        assert document.mod_time == updated_event["modTime"]
        assert any("Updated ingestion content" in chunk.content for chunk in chunks)

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

        await _wait_for_no_document(async_session_factory, provider_id, file_path, timeout=10.0)
    finally:
        await ingestion_service.stop()
        await client.close()
        async with async_engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
        await async_engine.dispose()
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))


@pytest.mark.asyncio
async def test_ingestion_retries_after_failure(nats_client, testserver_info: Dict[str, str], monkeypatch):
    if not _can_connect_db():
        pytest.skip("Postgres not available for pgvector integration test")

    monkeypatch.setenv("NATS_URL", testserver_info["nats_url"])

    async_engine = create_async_engine(_build_async_db_url(db_url))
    async_session_factory = async_sessionmaker(async_engine, expire_on_commit=False)
    async with async_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    config = FileChangedIngestionConfig(
        enabled=True,
        max_file_bytes=5 * 1024 * 1024,
        pull_batch=1,
        fetch_timeout=0.5,
        ack_wait=1.0,
        consumer_name=None,
        parallelism=1,
        idle_backoff_base=0.0,
        idle_backoff_max=0.0,
    )
    ingestion_service = FileChangedIngestionService(config)
    attempts = 0

    from ingestion import file_changed_consumer as file_changed_consumer_module

    original_extract_text = file_changed_consumer_module.extract_text

    def fail_once_extract_text(payload: bytes, mime: str) -> str:
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            raise RuntimeError("transient extract failure")
        return original_extract_text(payload, mime)

    monkeypatch.setattr(file_changed_consumer_module, "extract_text", fail_once_extract_text)

    js = nats_client.jetstream()
    try:
        await js.add_stream(name="SERAPH_FILE_CHANGED", subjects=["seraph.file.*.changed"])
    except Exception as exc:
        pytest.skip(f"JetStream not available: {exc}")

    provider_id = testserver_info["provider_id"]
    file_id = f"file-{secrets.token_hex(4)}"
    file_path = "test_ingestion_retry.txt"
    payload = b"Retry ingestion payload"

    client = FileProviderClient(provider_id, nats_client)
    try:
        file_handle = await client.open_file(file_path, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o644)
        await file_handle.write(payload)
        await file_handle.close()

        await ingestion_service.start()

        created_event = {
            "event": {"id": secrets.token_hex(6), "version": 1},
            "fileId": file_id,
            "providerId": provider_id,
            "change": "created",
            "path": file_path,
            "size": len(payload),
            "mode": 0,
            "modTime": int(time.time()),
            "isDir": False,
            "mime": "text/plain",
        }
        event_payload = _encode_file_changed_event(created_event)
        await js.publish(f"seraph.file.{file_id}.changed", event_payload)

        document, chunks = await _wait_for_document(
            async_session_factory,
            provider_id,
            file_path,
            timeout=10.0,
            predicate=lambda document, chunks: (
                document.ingest_status == "indexed"
                and any("Retry ingestion payload" in chunk.content for chunk in chunks)
            ),
        )
        assert document is not None
        assert attempts >= 2
        assert document.last_error is None
        assert any("Retry ingestion payload" in chunk.content for chunk in chunks)
    finally:
        await ingestion_service.stop()
        await client.close()
        async with async_engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
        await async_engine.dispose()
