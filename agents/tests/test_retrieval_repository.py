import sys
from pathlib import Path

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

sys.path.append(str(Path(__file__).resolve().parents[1]))

from db import db_url
from db.session import _build_async_db_url
from documents.models import Base, DocumentChunk, IndexedDocument
from retrieval.repository import PgVectorRetrievalRepository


def _can_connect_db() -> bool:
    try:
        engine = create_engine(db_url)
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        return False


@pytest.mark.asyncio
async def test_search_returns_ranked_chunks_with_chunk_counts_and_scope_filters() -> None:
    if not _can_connect_db():
        pytest.skip("Postgres not available for pgvector repository test")

    engine = create_engine(db_url)
    async_engine = create_async_engine(_build_async_db_url(db_url))

    try:
        with engine.begin() as conn:
            conn.execute(text("CREATE EXTENSION IF NOT EXISTS vector"))

        async with async_engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)

        session_factory = async_sessionmaker(async_engine, expire_on_commit=False)
        async with session_factory() as session:
            repo = PgVectorRetrievalRepository(session)

            visible_document = IndexedDocument(
                provider_id="provider-a",
                file_id="file-visible",
                path="/team/docs/plan.md",
                mime="text/plain",
                size=100,
                mod_time=1,
                content_hash="hash-visible",
                ingest_status="indexed",
                last_error=None,
            )
            hidden_document = IndexedDocument(
                provider_id="provider-a",
                file_id="file-hidden",
                path="/private/secret.md",
                mime="text/plain",
                size=100,
                mod_time=1,
                content_hash="hash-hidden",
                ingest_status="indexed",
                last_error=None,
            )
            other_provider_document = IndexedDocument(
                provider_id="provider-b",
                file_id="file-other",
                path="/team/docs/reference.md",
                mime="text/plain",
                size=100,
                mod_time=1,
                content_hash="hash-other",
                ingest_status="indexed",
                last_error=None,
            )
            root_document = IndexedDocument(
                provider_id="provider-a",
                file_id="file-root",
                path="/top-level.md",
                mime="text/plain",
                size=100,
                mod_time=1,
                content_hash="hash-root",
                ingest_status="indexed",
                last_error=None,
            )
            session.add_all([visible_document, hidden_document, other_provider_document, root_document])
            await session.flush()

            session.add_all(
                [
                    DocumentChunk(
                        document_id=visible_document.id,
                        chunk_index=0,
                        content="first visible chunk",
                        token_count=3,
                        embedding=[0.9, 0.1] + [0.0] * 1534,
                        metadata_json={},
                    ),
                    DocumentChunk(
                        document_id=visible_document.id,
                        chunk_index=1,
                        content="best visible chunk",
                        token_count=3,
                        embedding=[1.0, 0.0] + [0.0] * 1534,
                        metadata_json={},
                    ),
                    DocumentChunk(
                        document_id=hidden_document.id,
                        chunk_index=0,
                        content="hidden chunk",
                        token_count=2,
                        embedding=[1.0, 0.0] + [0.0] * 1534,
                        metadata_json={},
                    ),
                    DocumentChunk(
                        document_id=other_provider_document.id,
                        chunk_index=0,
                        content="other provider chunk",
                        token_count=3,
                        embedding=[1.0, 0.0] + [0.0] * 1534,
                        metadata_json={},
                    ),
                    DocumentChunk(
                        document_id=root_document.id,
                        chunk_index=0,
                        content="root chunk",
                        token_count=2,
                        embedding=[1.0, 0.0] + [0.0] * 1534,
                        metadata_json={},
                    ),
                ]
            )
            await session.commit()

        async with session_factory() as session:
            repo = PgVectorRetrievalRepository(session)

            results = await repo.search(
                embedding=[1.0, 0.0] + [0.0] * 1534,
                scopes=[("provider-a", "/team/docs")],
                limit=5,
            )

        assert [result.path for result in results] == ["/team/docs/plan.md", "/team/docs/plan.md"]
        assert [result.chunk_index for result in results] == [1, 0]
        assert all(result.total_chunks == 2 for result in results)
        assert results[0].chunk_id
        assert results[0].document_id == visible_document.id
        assert results[0].provider_id == "provider-a"
        assert results[0].content == "best visible chunk"
        assert results[0].score > results[1].score

        async with session_factory() as session:
            repo = PgVectorRetrievalRepository(session)

            root_results = await repo.search(
                embedding=[1.0, 0.0] + [0.0] * 1534,
                scopes=[("provider-a", "/")],
                limit=5,
            )

        assert any(result.path == "/top-level.md" for result in root_results)
        assert all(result.provider_id == "provider-a" for result in root_results)
    finally:
        async with async_engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
        await async_engine.dispose()
        engine.dispose()
