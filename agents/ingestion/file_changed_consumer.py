"""JetStream consumer that ingests FileChangedEvent documents into the knowledge base."""

from __future__ import annotations

import asyncio
import logging
import os
from dataclasses import dataclass
from typing import Optional

from nats import errors as nats_errors
from nats.js import api as js_api
from sqlalchemy import select

from agno.knowledge.content import Content, FileData
from agno.utils.log import logger as agno_logger
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
    idle_backoff_base: float
    idle_backoff_max: float


class FileChangedIngestionService:
    def __init__(
        self,
        config: FileChangedIngestionConfig,
        logger: Optional[logging.Logger] = None,
        knowledge=None,
    ) -> None:
        self._config = config
        self._log = self._configure_logger(logger)
        self._knowledge = knowledge or user_documents_knowledge
        self._nc = None
        self._js = None
        self._sub = None
        self._task: Optional[asyncio.Task] = None
        self._stop_event = asyncio.Event()
        self._semaphore = asyncio.Semaphore(config.parallelism)
        self._tasks: set[asyncio.Task] = set()
        self._idle_backoff = config.idle_backoff_base

    def _configure_logger(self, logger: Optional[logging.Logger]) -> logging.Logger:
        if logger is not None:
            return logger

        ingest_logger = agno_logger
        level_name = os.getenv("LOG_LEVEL")
        if level_name:
            try:
                ingest_logger.setLevel(level_name.upper())
            except ValueError:
                ingest_logger.setLevel(logging.INFO)
        return ingest_logger

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
            except (nats_errors.TimeoutError, asyncio.TimeoutError):
                await self._sleep_idle_backoff()
                continue
            except asyncio.CancelledError:
                return
            except Exception as exc:
                self._log.exception("Failed to fetch messages", exc_info=exc)
                await asyncio.sleep(1)
                continue

            self._reset_idle_backoff()
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

    def _reset_idle_backoff(self) -> None:
        self._idle_backoff = self._config.idle_backoff_base

    async def _sleep_idle_backoff(self) -> None:
        if self._idle_backoff <= 0:
            return
        await asyncio.sleep(self._idle_backoff)
        self._idle_backoff = min(self._idle_backoff * 2, self._config.idle_backoff_max)

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

        self._log.debug(
            "Processing FileChangedEvent",
            extra={
                "event_id": event.event_id,
                "change": event.change,
                "path": event.path,
                "mime": event.mime,
                "provider_id": event.provider_id,
                "file_id": event.file_id,
            },
        )

        if event.is_dir:
            self._log.debug("Skipping directory event", extra={"path": event.path})
            return

        if not event.path or not event.provider_id:
            self._log.warning("Skipping event with missing path/provider", extra={"event": event})
            return

        normalized_mime = _normalize_mime(event.mime)

        if event.change == "deleted":
            self._knowledge.remove_vectors_by_metadata({"file_id": event.file_id, "provider_id": event.provider_id})
            self._log.debug(
                "Processed delete event",
                extra={"path": event.path, "provider_id": event.provider_id, "file_id": event.file_id},
            )
            return

        if not _is_supported_mime(normalized_mime):
            self._log.debug(
                "Skipping unsupported mime",
                extra={"mime": normalized_mime, "path": event.path, "provider_id": event.provider_id},
            )
            return

        if event.size and event.size > self._config.max_file_bytes:
            self._log.debug(
                "Skipping large file",
                extra={"path": event.path, "size": event.size, "limit": self._config.max_file_bytes},
            )
            return

        await self._ingest_file(event, normalized_mime)
        self._log.info(
            "Ingested file",
            extra={"path": event.path, "provider_id": event.provider_id, "file_id": event.file_id},
        )
        self._log.debug(
            "Ingestion completed",
            extra={"path": event.path, "provider_id": event.provider_id, "file_id": event.file_id},
        )

    async def _ingest_file(self, event: FileChangedEvent, normalized_mime: str) -> None:
        if self._nc is None:
            raise RuntimeError("NATS client not available")

        doc_name = os.path.basename(event.path) or event.path
        metadata = _build_metadata(event, normalized_mime)
        content_hash = self._build_content_hash(doc_name, normalized_mime)

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
                raise RuntimeError("PDF reader not available; ensure pypdf is installed")

            await self._knowledge.ainsert(
                name=doc_name,
                text_content=payload,
                metadata=metadata,
                reader=pdf_reader,
            )
            self._ensure_ingested(metadata, content_hash)
            return

        text = payload.decode("utf-8", errors="replace")
        await self._knowledge.ainsert(
            name=doc_name,
            text_content=text,
            metadata=metadata,
        )
        self._ensure_ingested(metadata, content_hash)

    def _build_content_hash(self, name: str, mime: str) -> str:
        file_data = FileData(content=b"", type="Text")
        if mime == "application/pdf":
            file_data = FileData(content=b"", type="Text")
        content = Content(name=name, file_data=file_data)
        return self._knowledge._build_content_hash(content)

    def _ensure_ingested(self, metadata: dict, content_hash: str) -> None:
        vector_db = self._knowledge.vector_db
        if vector_db is None:
            raise RuntimeError("Vector database not configured")
        if hasattr(vector_db, "Session") and hasattr(vector_db, "table"):
            try:
                with vector_db.Session() as sess, sess.begin():
                    stmt = select(vector_db.table.c.id).where(vector_db.table.c.meta_data.contains(metadata)).limit(1)
                    row = sess.execute(stmt).fetchone()
                if row is not None:
                    return
            except Exception as exc:
                self._log.warning("Metadata verification failed", exc_info=exc)
        if not vector_db.content_hash_exists(content_hash):
            raise RuntimeError("Embedding insert failed; will retry")


def build_ingestion_config() -> FileChangedIngestionConfig:
    return FileChangedIngestionConfig(
        enabled=_env_bool("KB_INGEST_ENABLED", True),
        max_file_bytes=int(os.getenv("KB_MAX_FILE_BYTES", str(20 * 1024 * 1024))),
        pull_batch=int(os.getenv("KB_PULL_BATCH", "20")),
        fetch_timeout=float(os.getenv("KB_FETCH_TIMEOUT", "10.0")),
        ack_wait=float(os.getenv("KB_ACK_WAIT_SECONDS", "30")),
        consumer_name=os.getenv("KB_CONSUMER_NAME", "seraph-agents-kb"),
        parallelism=max(1, int(os.getenv("KB_INGEST_PARALLELISM", "4"))),
        idle_backoff_base=float(os.getenv("KB_IDLE_BACKOFF_BASE", "0.5")),
        idle_backoff_max=float(os.getenv("KB_IDLE_BACKOFF_MAX", "5.0")),
    )


def create_ingestion_service(
    logger: Optional[logging.Logger] = None,
    config: Optional[FileChangedIngestionConfig] = None,
    knowledge=None,
) -> FileChangedIngestionService:
    return FileChangedIngestionService(config or build_ingestion_config(), logger=logger, knowledge=knowledge)
