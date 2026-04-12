import sys
import asyncio
from pathlib import Path

import pytest
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

sys.path.append(str(Path(__file__).resolve().parents[1]))

from documents.models import Base, DocumentChunk
from documents.repository import DocumentsRepository


@pytest.mark.asyncio
async def test_upsert_document_replaces_existing_chunks() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)

        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-1",
            path="/team/spec.md",
            mime="text/plain",
            size=10,
            mod_time=1,
            text="hello world",
        )
        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-1",
            path="/team/spec.md",
            mime="text/plain",
            size=12,
            mod_time=2,
            text="updated world",
        )

        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/spec.md")

    assert document is not None
    assert document.mod_time == 2
    assert [chunk.content for chunk in chunks] == ["updated world"]

    await engine.dispose()


@pytest.mark.asyncio
async def test_delete_document_removes_document_and_chunks() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)

        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-1",
            path="/team/spec.md",
            mime="text/plain",
            size=10,
            mod_time=1,
            text="hello world",
        )
        await repo.delete_document(provider_id="provider-a", path="/team/spec.md", mod_time=2)

        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/spec.md")

    assert document is None
    assert chunks == []

    await engine.dispose()


@pytest.mark.asyncio
async def test_upsert_document_splits_large_text_into_multiple_chunks() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)
        text = ("abcdefghij" * 130) + ("klmnopqrst" * 40)

        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-2",
            path="/team/large.txt",
            mime="text/plain",
            size=len(text),
            mod_time=3,
            text=text,
        )

        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/large.txt")

    assert document is not None
    assert len(chunks) > 1
    assert "".join(chunk.content for chunk in chunks).startswith(text[: len(chunks[0].content)])

    await engine.dispose()


@pytest.mark.asyncio
async def test_record_ingest_failure_updates_document_status() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)

        await repo.record_ingest_failure(
            provider_id="provider-a",
            file_id="file-3",
            path="/team/broken.txt",
            mime="text/plain",
            size=11,
            mod_time=4,
            error="boom",
        )

        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/broken.txt")

    assert document is not None
    assert document.ingest_status == "failed"
    assert document.last_error == "boom"
    assert chunks == []

    await engine.dispose()


@pytest.mark.asyncio
async def test_upsert_document_ignores_stale_mod_time() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)

        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-1",
            path="/team/spec.md",
            mime="text/plain",
            size=12,
            mod_time=5,
            text="newest text",
        )
        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-1",
            path="/team/spec.md",
            mime="text/plain",
            size=8,
            mod_time=4,
            text="stale",
        )

        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/spec.md")

    assert document is not None
    assert document.mod_time == 5
    assert [chunk.content for chunk in chunks] == ["newest text"]

    await engine.dispose()


@pytest.mark.asyncio
async def test_upsert_document_ignores_equal_mod_time() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)

        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-1",
            path="/team/spec.md",
            mime="text/plain",
            size=12,
            mod_time=5,
            text="first text",
        )
        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-1",
            path="/team/spec.md",
            mime="text/plain",
            size=13,
            mod_time=5,
            text="equal text",
        )

        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/spec.md")

    assert document is not None
    assert document.mod_time == 5
    assert [chunk.content for chunk in chunks] == ["first text"]

    await engine.dispose()


@pytest.mark.asyncio
async def test_record_ingest_failure_clears_existing_content_hash() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)

        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-3",
            path="/team/broken.txt",
            mime="text/plain",
            size=11,
            mod_time=3,
            text="hello world",
        )
        await repo.record_ingest_failure(
            provider_id="provider-a",
            file_id="file-3",
            path="/team/broken.txt",
            mime="text/plain",
            size=11,
            mod_time=4,
            error="boom",
        )

        document, _ = await repo.get_document_with_chunks("provider-a", "/team/broken.txt")

    assert document is not None
    assert document.content_hash == ""

    await engine.dispose()


@pytest.mark.asyncio
async def test_record_ingest_failure_ignores_stale_mod_time() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)

        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-3",
            path="/team/broken.txt",
            mime="text/plain",
            size=11,
            mod_time=5,
            text="fresh",
        )
        await repo.record_ingest_failure(
            provider_id="provider-a",
            file_id="file-3",
            path="/team/broken.txt",
            mime="text/plain",
            size=11,
            mod_time=4,
            error="stale boom",
        )

        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/broken.txt")

    assert document is not None
    assert document.mod_time == 5
    assert document.ingest_status == "indexed"
    assert document.last_error is None
    assert [chunk.content for chunk in chunks] == ["fresh"]

    await engine.dispose()


@pytest.mark.asyncio
async def test_record_ingest_failure_ignores_equal_mod_time() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)

        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-3",
            path="/team/broken.txt",
            mime="text/plain",
            size=11,
            mod_time=5,
            text="fresh",
        )
        await repo.record_ingest_failure(
            provider_id="provider-a",
            file_id="file-3",
            path="/team/broken.txt",
            mime="text/plain",
            size=11,
            mod_time=5,
            error="equal boom",
        )

        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/broken.txt")

    assert document is not None
    assert document.mod_time == 5
    assert document.ingest_status == "indexed"
    assert document.last_error is None
    assert [chunk.content for chunk in chunks] == ["fresh"]

    await engine.dispose()


@pytest.mark.asyncio
async def test_delete_document_ignores_stale_mod_time() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)

        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-6",
            path="/team/delete.txt",
            mime="text/plain",
            size=6,
            mod_time=5,
            text="keep me",
        )
        await repo.delete_document(provider_id="provider-a", path="/team/delete.txt", mod_time=4)

        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/delete.txt")

    assert document is not None
    assert document.mod_time == 5
    assert [chunk.content for chunk in chunks] == ["keep me"]

    await engine.dispose()


@pytest.mark.asyncio
async def test_delete_document_ignores_equal_mod_time() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)

        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-6",
            path="/team/delete.txt",
            mime="text/plain",
            size=6,
            mod_time=5,
            text="keep me",
        )
        await repo.delete_document(provider_id="provider-a", path="/team/delete.txt", mod_time=5)

        document, chunks = await repo.get_document_with_chunks("provider-a", "/team/delete.txt")

    assert document is not None
    assert document.mod_time == 5
    assert [chunk.content for chunk in chunks] == ["keep me"]

    await engine.dispose()


@pytest.mark.asyncio
async def test_document_chunks_enforce_unique_chunk_index_per_document() -> None:
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        repo = DocumentsRepository(db_session)
        document = await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-5",
            path="/team/constraint.txt",
            mime="text/plain",
            size=5,
            mod_time=1,
            text="hello",
        )

        db_session.add(
            DocumentChunk(
                document_id=document.id,
                chunk_index=0,
                content="duplicate",
                token_count=1,
                embedding=None,
                metadata_json={},
            )
        )

        with pytest.raises(IntegrityError):
            await db_session.commit()

    await engine.dispose()


class TrackingSession(AsyncSession):
    in_flight_executes = 0
    max_in_flight_executes = 0

    async def execute(self, statement, *args, **kwargs):
        type(self).in_flight_executes += 1
        type(self).max_in_flight_executes = max(type(self).max_in_flight_executes, type(self).in_flight_executes)
        try:
            await asyncio.sleep(0.05)
            return await super().execute(statement, *args, **kwargs)
        finally:
            type(self).in_flight_executes -= 1


@pytest.mark.asyncio
async def test_same_document_upserts_are_serialized(tmp_path: Path) -> None:
    db_path = tmp_path / "documents.db"
    engine = create_async_engine(f"sqlite+aiosqlite:///{db_path}")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    seed_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with seed_factory() as db_session:
        repo = DocumentsRepository(db_session)
        await repo.upsert_document(
            provider_id="provider-a",
            file_id="file-4",
            path="/team/race.txt",
            mime="text/plain",
            size=5,
            mod_time=1,
            text="seed",
        )

    TrackingSession.in_flight_executes = 0
    TrackingSession.max_in_flight_executes = 0
    session_factory = async_sessionmaker(engine, expire_on_commit=False, class_=TrackingSession)

    async def write(text: str, mod_time: int) -> None:
        async with session_factory() as db_session:
            repo = DocumentsRepository(db_session)
            await repo.upsert_document(
                provider_id="provider-a",
                file_id="file-4",
                path="/team/race.txt",
                mime="text/plain",
                size=len(text),
                mod_time=mod_time,
                text=text,
            )

    await asyncio.gather(
        write("a" * 1400, 2),
        write("b" * 1400, 3),
    )

    assert TrackingSession.max_in_flight_executes == 1

    await engine.dispose()
