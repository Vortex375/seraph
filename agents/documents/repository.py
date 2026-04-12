from __future__ import annotations

import asyncio
import hashlib

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from documents.chunking import chunk_text
from documents.models import DocumentChunk, IndexedDocument


class DocumentsRepository:
    _document_locks: dict[tuple[str, str], asyncio.Lock] = {}

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    @classmethod
    def _lock_for_document(cls, provider_id: str, path: str) -> asyncio.Lock:
        key = (provider_id, path)
        lock = cls._document_locks.get(key)
        if lock is None:
            lock = asyncio.Lock()
            cls._document_locks[key] = lock
        return lock

    @staticmethod
    def _is_stale(document: IndexedDocument | None, mod_time: int) -> bool:
        return document is not None and mod_time <= document.mod_time

    async def upsert_document(
        self,
        *,
        provider_id: str,
        file_id: str | None,
        path: str,
        mime: str,
        size: int,
        mod_time: int,
        text: str,
    ) -> IndexedDocument:
        async with self._lock_for_document(provider_id, path):
            content_hash = hashlib.sha256(text.encode("utf-8")).hexdigest()
            result = await self._session.execute(
                select(IndexedDocument).where(
                    IndexedDocument.provider_id == provider_id,
                    IndexedDocument.path == path,
                )
            )
            document = result.scalar_one_or_none()

            if document is not None and self._is_stale(document, mod_time):
                return document

            if document is None:
                document = IndexedDocument(
                    provider_id=provider_id,
                    file_id=file_id,
                    path=path,
                    mime=mime,
                    size=size,
                    mod_time=mod_time,
                    content_hash=content_hash,
                    ingest_status="indexed",
                    last_error=None,
                )
                self._session.add(document)
                await self._session.flush()
            else:
                document.file_id = file_id
                document.mime = mime
                document.size = size
                document.mod_time = mod_time
                document.content_hash = content_hash
                document.ingest_status = "indexed"
                document.last_error = None
                await self._session.execute(delete(DocumentChunk).where(DocumentChunk.document_id == document.id))

            for chunk in chunk_text(text):
                self._session.add(
                    DocumentChunk(
                        document_id=document.id,
                        chunk_index=chunk.index,
                        content=chunk.text,
                        token_count=len(chunk.text.split()),
                        embedding=None,
                        metadata_json={"start_offset": chunk.start_offset, "end_offset": chunk.end_offset},
                    )
                )

            await self._session.commit()
            await self._session.refresh(document)
            return document

    async def record_ingest_failure(
        self,
        *,
        provider_id: str,
        file_id: str | None,
        path: str,
        mime: str,
        size: int,
        mod_time: int,
        error: str,
    ) -> IndexedDocument:
        async with self._lock_for_document(provider_id, path):
            result = await self._session.execute(
                select(IndexedDocument).where(
                    IndexedDocument.provider_id == provider_id,
                    IndexedDocument.path == path,
                )
            )
            document = result.scalar_one_or_none()

            if document is not None and self._is_stale(document, mod_time):
                return document

            if document is None:
                document = IndexedDocument(
                    provider_id=provider_id,
                    file_id=file_id,
                    path=path,
                    mime=mime,
                    size=size,
                    mod_time=mod_time,
                    content_hash="",
                    ingest_status="failed",
                    last_error=error,
                )
                self._session.add(document)
                await self._session.flush()
            else:
                document.file_id = file_id
                document.mime = mime
                document.size = size
                document.mod_time = mod_time
                document.content_hash = ""
                document.ingest_status = "failed"
                document.last_error = error
                await self._session.execute(delete(DocumentChunk).where(DocumentChunk.document_id == document.id))

            await self._session.commit()
            await self._session.refresh(document)
            return document

    async def delete_document(self, *, provider_id: str, path: str, mod_time: int) -> None:
        result = await self._session.execute(
            select(IndexedDocument).where(
                IndexedDocument.provider_id == provider_id,
                IndexedDocument.path == path,
            )
        )
        document = result.scalar_one_or_none()
        if document is None:
            return
        if self._is_stale(document, mod_time):
            return

        await self._session.execute(delete(DocumentChunk).where(DocumentChunk.document_id == document.id))
        await self._session.delete(document)
        await self._session.commit()

    async def get_document_with_chunks(
        self, provider_id: str, path: str
    ) -> tuple[IndexedDocument | None, list[DocumentChunk]]:
        result = await self._session.execute(
            select(IndexedDocument).where(
                IndexedDocument.provider_id == provider_id,
                IndexedDocument.path == path,
            )
        )
        document = result.scalar_one_or_none()
        if document is None:
            return None, []

        chunk_result = await self._session.execute(
            select(DocumentChunk)
            .where(DocumentChunk.document_id == document.id)
            .order_by(DocumentChunk.chunk_index.asc())
        )
        return document, list(chunk_result.scalars().all())
