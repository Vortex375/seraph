from dataclasses import dataclass
from typing import Protocol

from sqlalchemy import Select, and_, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from documents.models import DocumentChunk, IndexedDocument


@dataclass(frozen=True)
class RetrievalResult:
    document_id: str
    chunk_id: str
    chunk_index: int
    total_chunks: int
    provider_id: str
    path: str
    content: str
    score: float


class RetrievalRepository(Protocol):
    async def search(
        self, embedding: list[float], scopes: list[tuple[str, str]], limit: int
    ) -> list[RetrievalResult]: ...


class PgVectorRetrievalRepository:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    @staticmethod
    def _scope_clause(provider_id: str, path_prefix: str):
        if path_prefix == "/":
            return IndexedDocument.provider_id == provider_id

        normalized_prefix = path_prefix.rstrip("/") or "/"
        return and_(
            IndexedDocument.provider_id == provider_id,
            or_(
                IndexedDocument.path == normalized_prefix,
                IndexedDocument.path.like(f"{normalized_prefix}/%"),
            ),
        )

    @classmethod
    def _build_query(cls, embedding: list[float], scopes: list[tuple[str, str]], limit: int) -> Select:
        distance = DocumentChunk.embedding.cosine_distance(embedding)
        score = (1 - distance).label("score")
        total_chunks = func.count(DocumentChunk.id).over(partition_by=DocumentChunk.document_id).label("total_chunks")

        scope_clauses = [cls._scope_clause(provider_id, path_prefix) for provider_id, path_prefix in scopes]

        return (
            select(
                IndexedDocument.id.label("document_id"),
                DocumentChunk.id.label("chunk_id"),
                DocumentChunk.chunk_index,
                total_chunks,
                IndexedDocument.provider_id,
                IndexedDocument.path,
                DocumentChunk.content,
                score,
            )
            .join(IndexedDocument, IndexedDocument.id == DocumentChunk.document_id)
            .where(
                DocumentChunk.embedding.is_not(None),
                IndexedDocument.ingest_status == "indexed",
                or_(*scope_clauses),
            )
            .order_by(distance.asc(), DocumentChunk.chunk_index.asc())
            .limit(limit)
        )

    async def search(self, embedding: list[float], scopes: list[tuple[str, str]], limit: int) -> list[RetrievalResult]:
        if not scopes or limit <= 0:
            return []

        result = await self._session.execute(self._build_query(embedding, scopes, limit))
        return [
            RetrievalResult(
                document_id=row.document_id,
                chunk_id=row.chunk_id,
                chunk_index=row.chunk_index,
                total_chunks=row.total_chunks,
                provider_id=row.provider_id,
                path=row.path,
                content=row.content,
                score=float(row.score),
            )
            for row in result
        ]
