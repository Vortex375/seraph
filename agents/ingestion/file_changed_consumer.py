"""JetStream consumer that ingests FileChangedEvent documents into the knowledge base."""

from __future__ import annotations

import asyncio
import logging
import os
from dataclasses import dataclass
from typing import Optional

from nats.js import api as js_api
from nats.js.errors import FetchTimeoutError

from fileprovider.client import FileProviderClient
from fileprovider.nats_client import connect_nats_from_env
from ingestion.file_changed_events import FileChangedEvent, decode_file_changed_event
from knowledge.user_documents import user_documents_knowledge

FILE_CHANGED_STREAM = "SERAPH_FILE_CHANGED"
FILE_CHANGED_SUBJECT = "seraph.file.*.changed"


def _env_bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _normalize_mime(mime: str) -> str:
    return mime.split(";")[0].strip().lower()


def _is_supported_mime(mime: str) -> bool:
    if mime.startswith("text/"):
        return True
    if mime == "application/pdf":
        return True
    if mime in {"application/json", "application/xml", "application/csv", "application/javascript", "application/sql"}:
        return True
    return False


def _build_metadata(event: FileChangedEvent, mime: str) -> dict:
    return {
        "file_id": event.file_id,
        "provider_id": event.provider_id,
        "path": event.path,
        "mime": mime,
        "size": event.size,
        "mod_time": event.mod_time,
    }


async def _read_all(file_handle, chunk_size: int) -> bytes:
    parts: list[bytes] = []
    while True:
        try:
            chunk = await file_handle.read(chunk_size)
        except EOFError:
            break
        if not chunk:
            break
        parts.append(chunk)
    return b"".join(parts)


@dataclass
class FileChangedIngestionConfig:
    enabled: bool
    max_file_bytes: int
    pull_batch: int
    fetch_timeout: float
    ack_wait: float
    consumer_name: Optional[str]
    parallelism: int


class FileChangedIngestionService:
    def __init__(
        self,
        config: FileChangedIngestionConfig,
        logger: Optional[logging.Logger] = None,
        knowledge=None,
    ) -> None:
        self._config = config
        self._log = logger or logging.getLogger("agents.ingestion")
        self._knowledge = knowledge or user_documents_knowledge
        self._nc = None
        self._js = None
        self._sub = None
        self._task: Optional[asyncio.Task] = None
        self._stop_event = asyncio.Event()
        self._semaphore = asyncio.Semaphore(config.parallelism)
        self._tasks: set[asyncio.Task] = set()

    async def start(self) -> None:
        if not self._config.enabled:
            self._log.info("Knowledge ingestion disabled")
            return
        if self._task is not None:
            return

        self._nc = await connect_nats_from_env()
        self._js = self._nc.jetstream()

        consumer_config = js_api.ConsumerConfig(
            ack_policy=js_api.AckPolicy.EXPLICIT,
            ack_wait=self._config.ack_wait,
            deliver_policy=js_api.DeliverPolicy.ALL,
            filter_subject=FILE_CHANGED_SUBJECT,
            max_deliver=5,
        )

        durable_name = self._config.consumer_name or None
        if durable_name:
            consumer_config.durable_name = durable_name

        self._sub = await self._js.pull_subscribe(
            FILE_CHANGED_SUBJECT,
            stream=FILE_CHANGED_STREAM,
            durable=durable_name,
            config=consumer_config,
        )

        self._task = asyncio.create_task(self._run_loop())
        self._log.info("Started FileChangedEvent ingestion")

    async def stop(self) -> None:
        if self._task is None:
            return
        self._stop_event.set()
        await self._task
        self._task = None

        if self._sub is not None:
            await self._sub.unsubscribe()
            self._sub = None

        if self._nc is not None:
            await self._nc.close()
            self._nc = None

        self._log.info("Stopped FileChangedEvent ingestion")

    async def _run_loop(self) -> None:
        if self._sub is None:
            return

        while not self._stop_event.is_set():
            try:
                messages = await self._sub.fetch(self._config.pull_batch, timeout=self._config.fetch_timeout)
            except FetchTimeoutError:
                continue
            except Exception as exc:
                self._log.exception("Failed to fetch messages", exc_info=exc)
                await asyncio.sleep(1)
                continue

            for msg in messages:
                await self._semaphore.acquire()
                task = asyncio.create_task(self._handle_message(msg))
                self._tasks.add(task)
                task.add_done_callback(self._task_done)

        if self._tasks:
            await asyncio.gather(*self._tasks, return_exceptions=True)

    def _task_done(self, task: asyncio.Task) -> None:
        self._tasks.discard(task)
        self._semaphore.release()

    async def _handle_message(self, msg) -> None:
        try:
            await self._process_message(msg)
            await msg.ack()
        except Exception as exc:
            self._log.exception("Failed to process FileChangedEvent", exc_info=exc)
            try:
                await msg.nak()
            except Exception:
                self._log.debug("Failed to NAK message", exc_info=True)

    async def _process_message(self, msg) -> None:
        try:
            event = decode_file_changed_event(msg.data)
        except Exception as exc:
            self._log.error("Failed to decode FileChangedEvent", exc_info=exc)
            return

        if event.is_dir:
            return

        if not event.path or not event.provider_id:
            self._log.warning("Skipping event with missing path/provider", extra={"event": event})
            return

        normalized_mime = _normalize_mime(event.mime)

        if event.change == "deleted":
            self._knowledge.remove_vectors_by_metadata({"file_id": event.file_id, "provider_id": event.provider_id})
            return

        if not _is_supported_mime(normalized_mime):
            self._log.debug("Skipping unsupported mime", extra={"mime": normalized_mime, "path": event.path})
            return

        if event.size and event.size > self._config.max_file_bytes:
            self._log.info(
                "Skipping large file",
                extra={"path": event.path, "size": event.size, "limit": self._config.max_file_bytes},
            )
            return

        await self._ingest_file(event, normalized_mime)

    async def _ingest_file(self, event: FileChangedEvent, normalized_mime: str) -> None:
        if self._nc is None:
            raise RuntimeError("NATS client not available")

        doc_name = os.path.basename(event.path) or event.path
        metadata = _build_metadata(event, normalized_mime)

        self._knowledge.remove_vectors_by_metadata({"file_id": event.file_id, "provider_id": event.provider_id})

        client = FileProviderClient(event.provider_id, self._nc, self._log)
        file_handle = await client.open_file(event.path, os.O_RDONLY, 0)
        try:
            if event.size:
                payload = await file_handle.read(event.size)
            else:
                payload = await _read_all(file_handle, chunk_size=512 * 1024)
        finally:
            await file_handle.close()
            await client.close()

        if not payload:
            self._log.info("Skipping empty file", extra={"path": event.path})
            return

        if normalized_mime == "application/pdf":
            pdf_reader = self._knowledge.pdf_reader
            if pdf_reader is None:
                self._log.error("PDF reader not available; ensure pypdf is installed")
                return

            await self._knowledge.ainsert(
                name=doc_name,
                text_content=payload,
                metadata=metadata,
                reader=pdf_reader,
            )
            return

        text = payload.decode("utf-8", errors="replace")
        await self._knowledge.ainsert(
            name=doc_name,
            text_content=text,
            metadata=metadata,
        )


def build_ingestion_config() -> FileChangedIngestionConfig:
    return FileChangedIngestionConfig(
        enabled=_env_bool("KB_INGEST_ENABLED", True),
        max_file_bytes=int(os.getenv("KB_MAX_FILE_BYTES", str(20 * 1024 * 1024))),
        pull_batch=int(os.getenv("KB_PULL_BATCH", "20")),
        fetch_timeout=float(os.getenv("KB_FETCH_TIMEOUT", "1.0")),
        ack_wait=float(os.getenv("KB_ACK_WAIT_SECONDS", "30")),
        consumer_name=os.getenv("KB_CONSUMER_NAME", "seraph-agents-kb"),
        parallelism=max(1, int(os.getenv("KB_INGEST_PARALLELISM", "4"))),
    )


def create_ingestion_service(
    logger: Optional[logging.Logger] = None,
    config: Optional[FileChangedIngestionConfig] = None,
    knowledge=None,
) -> FileChangedIngestionService:
    return FileChangedIngestionService(config or build_ingestion_config(), logger=logger, knowledge=knowledge)
