# Agno to AgentScope Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `agents` package's Agno/AgentOS runtime with a FastAPI + AgentScope service that indexes canonical Seraph files into pgvector, enforces access through Seraph spaces during retrieval, and serves a small multi-session chat SPA.

**Architecture:** Keep Seraph-specific concerns custom at the boundaries: canonical indexing, spaces authorization, and FastAPI transport. Reuse AgentScope for the conversational core: `ReActAgent`, `AsyncSQLAlchemyMemory`, custom `KnowledgeBase` integration, and `stream_printing_messages(...)` for SSE. Persist chat session metadata and document index state in Postgres, and keep the existing NATS + fileprovider ingestion path.

**Tech Stack:** Python 3.12, FastAPI, AgentScope, SQLAlchemy, PostgreSQL + pgvector, NATS JetStream, OpenAI-compatible chat/embedding clients, pytest, ruff, mypy

---

## File Structure

Planned file layout and responsibilities:

- `agents/app/main.py`
  FastAPI bootstrap, lifespan, router registration, static SPA mounting.
- `agents/app/settings.py`
  Typed environment/config loading for model, DB, NATS, and Seraph auth/spaces settings.
- `agents/app/otel.py`
  OpenTelemetry and AgentScope tracing setup.
- `agents/api/chat.py`
  Session CRUD, message creation, and SSE stream endpoints.
- `agents/api/documents.py`
  Document status/debug endpoints.
- `agents/api/models.py`
  Pydantic request/response models for the REST API.
- `agents/auth/current_user.py`
  Request-scoped Seraph user resolution.
- `agents/spaces/client.py`
  NATS-backed integration for `GetSpacesForUser`-equivalent lookups.
- `agents/spaces/access.py`
  Provider/path prefix authorization filtering.
- `agents/chat/session_service.py`
  Session metadata CRUD and ownership checks.
- `agents/chat/agent_factory.py`
  Builds `ReActAgent` instances with AgentScope memory, formatter, model, toolkit, and knowledge.
- `agents/chat/prompts.py`
  System prompt constants for grounded document chat.
- `agents/chat/streaming.py`
  Adapter from `stream_printing_messages(...)` to SSE events.
- `agents/chat/citations.py`
  Citation persistence and response shaping.
- `agents/knowledge/seraph_knowledge.py`
  Custom AgentScope `KnowledgeBase` implementation backed by Seraph retrieval.
- `agents/retrieval/repository.py`
  pgvector retrieval queries over indexed chunks.
- `agents/retrieval/service.py`
  Query embedding + spaces filtering + retrieval orchestration.
- `agents/documents/models.py`
  SQLAlchemy models for canonical documents, chunks, citations, failures, and chat session metadata.
- `agents/documents/repository.py`
  Canonical upsert/delete/status repository code for documents and chunks.
- `agents/documents/chunking.py`
  Deterministic text chunking logic.
- `agents/ingestion/file_changed_consumer.py`
  Refactored ingestion service that writes canonical documents/chunks instead of Agno knowledge rows.
- `agents/ingestion/content.py`
  Content extraction helpers for text/PDF payloads.
- `agents/db/session.py`
  Async engine/session factory shared by app, repositories, and AgentScope memory.
- `agents/db/schema.py`
  Schema creation helpers used by app startup and tests for the first iteration.
- `agents/ui/package.json`
  Minimal SPA toolchain.
- `agents/ui/src/*`
  Session list + chat timeline SPA.
- `agents/tests/test_auth_current_user.py`
  Request user resolution tests.
- `agents/tests/test_spaces_access.py`
  Spaces prefix authorization tests.
- `agents/tests/test_documents_repository.py`
  Canonical document upsert/delete tests.
- `agents/tests/test_seraph_knowledge.py`
  Custom AgentScope knowledge adapter tests.
- `agents/tests/test_chat_api.py`
  Session CRUD and message endpoint tests.
- `agents/tests/test_chat_streaming.py`
  SSE streaming behavior tests.
- `agents/tests/test_ingestion_integration.py`
  Existing integration test refactored to assert canonical document/chunk persistence.

### Task 1: Replace Agno/AgentOS Bootstrap and Dependencies

**Files:**
- Create: `agents/app/settings.py`
- Create: `agents/app/otel.py`
- Modify: `agents/app/main.py`
- Modify: `agents/pyproject.toml`
- Modify: `agents/requirements.txt`
- Modify: `agents/compose.yaml`
- Modify: `agents/README.md`
- Test: `agents/tests/test_app_bootstrap.py`

- [ ] **Step 1: Write the failing bootstrap test**

```python
from fastapi.testclient import TestClient

from app.main import create_app
from app.settings import Settings


def test_create_app_exposes_health_endpoint() -> None:
    app = create_app()

    with TestClient(app) as client:
        response = client.get('/healthz')

    assert response.status_code == 200
    assert response.json() == {'status': 'ok'}
    assert isinstance(app.state.settings, Settings)
```

- [ ] **Step 2: Run the bootstrap test to verify it fails**

Run: `pytest agents/tests/test_app_bootstrap.py -v`
Expected: FAIL because `create_app` and `/healthz` do not exist.

- [ ] **Step 3: Replace Agno dependencies with AgentScope dependencies**

Update `agents/pyproject.toml` dependencies to remove:

```toml
"agno",
"agno-infra",
"openinference-instrumentation-agno",
```

and add:

```toml
"agentscope",
"sse-starlette",
"pydantic-settings",
"alembic",
"opentelemetry-instrumentation-fastapi",
```

Update mypy overrides to replace `agno.*` with:

```toml
module = ["pgvector.*", "setuptools.*", "agentscope.*", "duckdb.*"]
ignore_missing_imports = true
```

- [ ] **Step 4: Add typed settings for the new service**

Create `agents/app/settings.py`:

```python
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file='.env', env_file_encoding='utf-8', extra='ignore')

    app_host: str = '0.0.0.0'
    app_port: int = 8000
    runtime_env: str = 'prd'

    openai_api_key: str | None = None
    openai_base_url: str | None = None
    chat_model_name: str = 'gpt-5.2'
    embedding_model_name: str = 'text-embedding-3-small'
    embedding_dimensions: int = 1536

    db_host: str = 'localhost'
    db_port: int = 5432
    db_user: str = 'ai'
    db_pass: str = 'ai'
    db_database: str = 'ai'

    nats_url: str = 'nats://localhost:4222'
    kb_ingest_enabled: bool = True
    kb_max_file_bytes: int = 20 * 1024 * 1024
    kb_pull_batch: int = 20
    kb_fetch_timeout: float = 10.0
    kb_ack_wait_seconds: float = 30.0
    kb_consumer_name: str = 'seraph-agents-kb'
    kb_ingest_parallelism: int = 4
    kb_idle_backoff_base: float = 0.5
    kb_idle_backoff_max: float = 5.0

    seraph_auth_user_header: str = 'X-Seraph-User'


@lru_cache
def get_settings() -> Settings:
    return Settings()
```

- [ ] **Step 5: Replace `app/main.py` with a FastAPI app factory**

Implement `agents/app/main.py` as:

```python
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI

from app.otel import setup_telemetry
from app.settings import get_settings


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.settings = get_settings()
    yield


def create_app() -> FastAPI:
    app = FastAPI(title='Seraph Agents', lifespan=lifespan)
    setup_telemetry(app)

    @app.get('/healthz')
    async def healthz() -> dict[str, str]:
        return {'status': 'ok'}

    return app


app = create_app()


def main() -> None:
    settings = get_settings()
    uvicorn.run('app.main:app', host=settings.app_host, port=settings.app_port, reload=settings.runtime_env == 'dev')


if __name__ == '__main__':
    main()
```

- [ ] **Step 6: Update compose and requirements for the new runtime**

Update `agents/compose.yaml` service names and env entries to remove Agno-specific naming such as `agentos-api`/`agentos-db` and replace them with `agents-api`/`agents-db` while preserving the same port mapping and mounted volumes.

Run `./scripts/generate_requirements.sh` from `agents/` so `agents/requirements.txt` matches the new AgentScope dependency set from `pyproject.toml`.

- [ ] **Step 7: Run the bootstrap test to verify it passes**

Run: `pytest agents/tests/test_app_bootstrap.py -v`
Expected: PASS

- [ ] **Step 8: Run static checks for the touched files**

Run: `ruff check agents/app/main.py agents/app/settings.py agents/app/otel.py agents/tests/test_app_bootstrap.py`
Expected: PASS

Run: `mypy agents/app/main.py agents/app/settings.py agents/app/otel.py`
Expected: PASS

- [ ] **Step 9: Commit the bootstrap slice**

```bash
git add agents/app/main.py agents/app/settings.py agents/app/otel.py agents/pyproject.toml agents/requirements.txt agents/compose.yaml agents/README.md agents/tests/test_app_bootstrap.py
git commit -m "refactor: replace agentos bootstrap with fastapi app"
```

### Task 2: Add Session Metadata, Auth Resolution, and Spaces Access Checks

**Files:**
- Create: `agents/auth/current_user.py`
- Create: `agents/spaces/client.py`
- Create: `agents/spaces/access.py`
- Create: `agents/chat/session_service.py`
- Create: `agents/documents/models.py`
- Modify: `agents/db/session.py`
- Modify: `agents/app/main.py`
- Test: `agents/tests/test_auth_current_user.py`
- Test: `agents/tests/test_spaces_access.py`
- Test: `agents/tests/test_session_service.py`

- [ ] **Step 1: Write the failing current-user test**

```python
from fastapi import FastAPI, Depends
from fastapi.testclient import TestClient

from auth.current_user import AuthenticatedUser, get_current_user


def test_current_user_reads_seraph_header() -> None:
    app = FastAPI()

    @app.get('/me')
    async def me(user: AuthenticatedUser = Depends(get_current_user)) -> dict[str, str]:
        return {'user_id': user.user_id}

    client = TestClient(app)
    response = client.get('/me', headers={'X-Seraph-User': 'alice'})

    assert response.status_code == 200
    assert response.json() == {'user_id': 'alice'}
```

- [ ] **Step 2: Write the failing spaces access test**

```python
from spaces.access import SpaceScope, filter_allowed_documents


def test_filter_allowed_documents_keeps_matching_provider_prefix() -> None:
    scopes = [SpaceScope(provider_id='provider-a', path_prefix='/team/docs')]
    docs = [
        {'provider_id': 'provider-a', 'path': '/team/docs/spec.md'},
        {'provider_id': 'provider-a', 'path': '/private/spec.md'},
    ]

    allowed = filter_allowed_documents(scopes, docs)

    assert allowed == [{'provider_id': 'provider-a', 'path': '/team/docs/spec.md'}]
```

- [ ] **Step 3: Write the failing session metadata test**

```python
import asyncio

import pytest
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from chat.session_service import SessionService
from documents.models import Base


@pytest.mark.asyncio
async def test_create_session_belongs_to_request_user() -> None:
    engine = create_async_engine('sqlite+aiosqlite:///:memory:')
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

    session_factory = async_sessionmaker(engine, expire_on_commit=False)
    async with session_factory() as db_session:
        service = SessionService(db_session)
        session = await service.create_session(user_id='alice', title='Inbox')

    assert session.user_id == 'alice'
    assert session.title == 'Inbox'

    await engine.dispose()
```

- [ ] **Step 4: Run the new tests to verify they fail**

Run: `pytest agents/tests/test_auth_current_user.py agents/tests/test_spaces_access.py agents/tests/test_session_service.py -v`
Expected: FAIL because the auth, spaces, and session modules do not exist.

- [ ] **Step 5: Add chat session metadata models**

Create the SQLAlchemy models in `agents/documents/models.py`:

```python
from datetime import datetime
from uuid import uuid4

from sqlalchemy import DateTime, ForeignKey, String, Text
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column


class Base(DeclarativeBase):
    pass


class ChatSession(Base):
    __tablename__ = 'chat_sessions'

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    user_id: Mapped[str] = mapped_column(String(255), index=True)
    title: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow, onupdate=datetime.utcnow)
    last_message_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
```

- [ ] **Step 6: Add async DB session helpers**

Replace `agents/db/session.py` with async SQLAlchemy engine/session creation:

```python
from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from db.url import db_url


engine = create_async_engine(db_url.replace('postgresql+psycopg://', 'postgresql+psycopg_async://'), future=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


async def get_db_session() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session
```

Keep a minimal temporary `get_postgres_db(...)` compatibility export in `agents/db/session.py` if needed to avoid breaking `db.__init__` and other pre-cleanup imports before Task 7 removes the remaining Agno-era modules.

- [ ] **Step 7: Add auth and spaces helpers**

Create `agents/auth/current_user.py`:

```python
from dataclasses import dataclass

from fastapi import Header, HTTPException, status


@dataclass(frozen=True)
class AuthenticatedUser:
    user_id: str


async def get_current_user(x_seraph_user: str | None = Header(default=None, alias='X-Seraph-User')) -> AuthenticatedUser:
    if not x_seraph_user:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail='missing authenticated user')
    return AuthenticatedUser(user_id=x_seraph_user)
```

Create `agents/spaces/access.py`:

```python
from dataclasses import dataclass


@dataclass(frozen=True)
class SpaceScope:
    provider_id: str
    path_prefix: str


def _path_allowed(path_prefix: str, path: str) -> bool:
    normalized_prefix = path_prefix.rstrip('/') or '/'
    normalized_path = path.rstrip('/') or '/'
    return normalized_path == normalized_prefix or normalized_path.startswith(normalized_prefix + '/')


def filter_allowed_documents(scopes: list[SpaceScope], documents: list[dict]) -> list[dict]:
    return [
        doc
        for doc in documents
        if any(scope.provider_id == doc['provider_id'] and _path_allowed(scope.path_prefix, doc['path']) for scope in scopes)
    ]
```

- [ ] **Step 8: Add a NATS-backed spaces client and session service**

Create `agents/spaces/client.py` with a small client interface:

```python
from dataclasses import dataclass
import json

from nats.aio.client import Client as NatsClient

from spaces.access import SpaceScope


SPACE_CRUD_TOPIC = 'seraph.spaces.crud'


@dataclass(frozen=True)
class SpacesClient:
    nc: NatsClient

    async def get_scopes_for_user(self, user_id: str) -> list[SpaceScope]:
        payload = {'operation': 'READ', 'space': {'users': [user_id]}}
        msg = await self.nc.request(SPACE_CRUD_TOPIC, json.dumps(payload).encode('utf-8'), timeout=5.0)
        body = json.loads(msg.data)
        scopes: list[SpaceScope] = []
        for space in body.get('space', []):
            for provider in space.get('fileProviders', []):
                scopes.append(SpaceScope(provider_id=provider['providerId'], path_prefix=provider['path']))
        return scopes
```

Create `agents/chat/session_service.py`:

```python
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from documents.models import ChatSession


class SessionService:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def create_session(self, user_id: str, title: str) -> ChatSession:
        chat_session = ChatSession(user_id=user_id, title=title)
        self._session.add(chat_session)
        await self._session.commit()
        await self._session.refresh(chat_session)
        return chat_session

    async def list_sessions(self, user_id: str) -> list[ChatSession]:
        result = await self._session.execute(select(ChatSession).where(ChatSession.user_id == user_id))
        return list(result.scalars().all())
```

- [ ] **Step 9: Run the tests to verify they pass**

Run: `pytest agents/tests/test_auth_current_user.py agents/tests/test_spaces_access.py agents/tests/test_session_service.py -v`
Expected: PASS

- [ ] **Step 10: Commit the auth and spaces slice**

```bash
git add agents/auth/current_user.py agents/spaces/client.py agents/spaces/access.py agents/chat/session_service.py agents/documents/models.py agents/db/session.py agents/tests/test_auth_current_user.py agents/tests/test_spaces_access.py agents/tests/test_session_service.py
git commit -m "feat: add seraph auth and spaces-aware session metadata"
```

### Task 3: Build Canonical Document Storage and Refactor Ingestion

**Files:**
- Create: `agents/documents/repository.py`
- Create: `agents/documents/chunking.py`
- Create: `agents/ingestion/content.py`
- Modify: `agents/ingestion/file_changed_consumer.py`
- Modify: `agents/documents/models.py`
- Modify: `agents/tests/test_ingestion_integration.py`
- Test: `agents/tests/test_documents_repository.py`
- Test: `agents/tests/test_chunking.py`

- [ ] **Step 1: Write the failing chunking test**

```python
from documents.chunking import chunk_text


def test_chunk_text_preserves_order_and_offsets() -> None:
    chunks = chunk_text('alpha beta gamma delta', chunk_size=10, overlap=2)

    assert [chunk.index for chunk in chunks] == [0, 1, 2]
    assert chunks[0].text.startswith('alpha')
    assert chunks[-1].text.endswith('delta')
```

- [ ] **Step 2: Write the failing canonical upsert test**

```python
import pytest

from documents.repository import DocumentsRepository


@pytest.mark.asyncio
async def test_upsert_document_replaces_existing_chunks(db_session) -> None:
    repo = DocumentsRepository(db_session)

    await repo.upsert_document(
        provider_id='provider-a',
        file_id='file-1',
        path='/team/spec.md',
        mime='text/plain',
        size=10,
        mod_time=1,
        text='hello world',
    )
    await repo.upsert_document(
        provider_id='provider-a',
        file_id='file-1',
        path='/team/spec.md',
        mime='text/plain',
        size=12,
        mod_time=2,
        text='updated world',
    )

    document, chunks = await repo.get_document_with_chunks('provider-a', '/team/spec.md')

    assert document.mod_time == 2
    assert [chunk.content for chunk in chunks] == ['updated world']
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `pytest agents/tests/test_chunking.py agents/tests/test_documents_repository.py -v`
Expected: FAIL because the chunking and repository modules do not exist.

- [ ] **Step 4: Extend the document models for canonical indexing**

Add to `agents/documents/models.py`:

```python
from sqlalchemy import JSON, Integer, LargeBinary, UniqueConstraint
from pgvector.sqlalchemy import Vector


class IndexedDocument(Base):
    __tablename__ = 'documents'
    __table_args__ = (UniqueConstraint('provider_id', 'path', name='uq_documents_provider_path'),)

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    provider_id: Mapped[str] = mapped_column(String(255), index=True)
    file_id: Mapped[str | None] = mapped_column(String(255), nullable=True, index=True)
    path: Mapped[str] = mapped_column(Text)
    mime: Mapped[str] = mapped_column(String(255))
    size: Mapped[int] = mapped_column(Integer)
    mod_time: Mapped[int] = mapped_column(Integer)
    content_hash: Mapped[str] = mapped_column(String(255))
    ingest_status: Mapped[str] = mapped_column(String(32), default='indexed')
    last_error: Mapped[str | None] = mapped_column(Text, nullable=True)


class DocumentChunk(Base):
    __tablename__ = 'document_chunks'

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid4()))
    document_id: Mapped[str] = mapped_column(ForeignKey('documents.id', ondelete='CASCADE'), index=True)
    chunk_index: Mapped[int] = mapped_column(Integer)
    content: Mapped[str] = mapped_column(Text)
    token_count: Mapped[int] = mapped_column(Integer)
    embedding: Mapped[list[float]] = mapped_column(Vector(1536))
    metadata_json: Mapped[dict] = mapped_column(JSON, default=dict)
```

- [ ] **Step 5: Add deterministic chunking and canonical repository logic**

Create `agents/documents/chunking.py`:

```python
from dataclasses import dataclass


@dataclass(frozen=True)
class TextChunk:
    index: int
    text: str


def chunk_text(text: str, chunk_size: int = 1200, overlap: int = 150) -> list[TextChunk]:
    if not text:
        return []

    chunks: list[TextChunk] = []
    start = 0
    index = 0
    while start < len(text):
        end = min(len(text), start + chunk_size)
        chunks.append(TextChunk(index=index, text=text[start:end]))
        if end == len(text):
            break
        start = max(end - overlap, start + 1)
        index += 1
    return chunks
```

Create `agents/documents/repository.py` with an `upsert_document(...)` that deletes existing chunks for the same `(provider_id, path)`, updates the document row, and inserts fresh chunks.

- [ ] **Step 6: Add content extraction helpers**

Create `agents/ingestion/content.py`:

```python
from io import BytesIO

from pypdf import PdfReader


def extract_text(payload: bytes, mime: str) -> str:
    if mime == 'application/pdf':
        reader = PdfReader(BytesIO(payload))
        return '\n'.join(page.extract_text() or '' for page in reader.pages).strip()
    return payload.decode('utf-8', errors='replace')
```

- [ ] **Step 7: Refactor the ingestion service to use the repository**

In `agents/ingestion/file_changed_consumer.py`, replace Agno knowledge calls with repository calls of this shape:

```python
text = extract_text(payload, normalized_mime)
await repository.upsert_document(
    provider_id=event.provider_id,
    file_id=event.file_id,
    path=event.path,
    mime=normalized_mime,
    size=event.size,
    mod_time=event.mod_time,
    text=text,
)
```

and on delete:

```python
await repository.delete_document(provider_id=event.provider_id, path=event.path)
```

- [ ] **Step 8: Update the ingestion integration test to assert canonical rows**

Change `agents/tests/test_ingestion_integration.py` so it asserts rows in `documents` and `document_chunks` rather than Agno's `ai.<table_name>` knowledge tables.

For example:

```python
document, chunks = await repo.get_document_with_chunks(provider_id, file_path)
assert document.file_id == file_id
assert any('Updated ingestion content' in chunk.content for chunk in chunks)
```

- [ ] **Step 9: Run the unit and integration tests**

Run: `pytest agents/tests/test_chunking.py agents/tests/test_documents_repository.py -v`
Expected: PASS

Run: `pytest agents/tests/test_ingestion_integration.py -v`
Expected: PASS or SKIP if Postgres/JetStream test prerequisites are unavailable.

- [ ] **Step 10: Commit the indexing slice**

```bash
git add agents/documents/models.py agents/documents/repository.py agents/documents/chunking.py agents/ingestion/content.py agents/ingestion/file_changed_consumer.py agents/tests/test_chunking.py agents/tests/test_documents_repository.py agents/tests/test_ingestion_integration.py
git commit -m "feat: index canonical seraph documents into pgvector"
```

### Task 4: Add Space-Aware Retrieval Through a Custom AgentScope Knowledge Base

**Files:**
- Create: `agents/retrieval/repository.py`
- Create: `agents/retrieval/service.py`
- Create: `agents/knowledge/seraph_knowledge.py`
- Modify: `agents/spaces/client.py`
- Test: `agents/tests/test_retrieval_service.py`
- Test: `agents/tests/test_seraph_knowledge.py`

- [ ] **Step 1: Write the failing retrieval filter test**

```python
import pytest

from retrieval.repository import RetrievalResult
from retrieval.service import RetrievalService
from spaces.access import SpaceScope


class StubEmbedder:
    async def __call__(self, values: list[str]):
        return type('EmbeddingResponse', (), {'embeddings': [[0.1, 0.2, 0.3]]})()


class StubRepository:
    async def search(self, embedding: list[float], scopes: list[tuple[str, str]], limit: int):
        assert scopes == [('provider-a', '/team/docs')]
        return [
            RetrievalResult(
                document_id='doc-1',
                chunk_id='chunk-1',
                provider_id='provider-a',
                path='/team/docs/plan.md',
                content='project plan body',
                score=0.91,
            )
        ]


@pytest.mark.asyncio
async def test_retrieval_only_returns_chunks_inside_visible_spaces() -> None:
    service = RetrievalService(embedder=StubEmbedder(), repo=StubRepository())

    results = await service.retrieve(
        query='project plan',
        scopes=[SpaceScope(provider_id='provider-a', path_prefix='/team/docs')],
        limit=5,
    )

    assert all(result.provider_id == 'provider-a' for result in results)
    assert all(result.path.startswith('/team/docs') for result in results)
```

- [ ] **Step 2: Write the failing AgentScope knowledge test**

```python
import pytest

from agentscope.message import TextBlock
from retrieval.repository import RetrievalResult
from knowledge.seraph_knowledge import SeraphKnowledgeBase
from spaces.access import SpaceScope


class StubSpacesClient:
    async def get_scopes_for_user(self, user_id: str):
        assert user_id == 'alice'
        return [SpaceScope(provider_id='provider-a', path_prefix='/team/docs')]


class StubRetrievalService:
    async def retrieve(self, query: str, scopes, limit: int = 5):
        return [
            RetrievalResult(
                document_id='doc-1',
                chunk_id='chunk-1',
                provider_id='provider-a',
                path='/team/docs/release.md',
                content='release notes body',
                score=0.95,
            )
        ]


@pytest.mark.asyncio
async def test_seraph_knowledge_returns_agentscope_documents() -> None:
    knowledge = SeraphKnowledgeBase(
        embedding_store=None,
        embedding_model=None,
        retrieval_service=StubRetrievalService(),
        spaces_client=StubSpacesClient(),
        user_id='alice',
    )

    docs = await knowledge.retrieve('release notes', limit=3)

    assert len(docs) == 1
    assert docs[0].metadata.content['text'] == 'release notes body'
    content = cast(TextBlock, docs[0].metadata.content)
    assert content['path'] == '/team/docs/release.md'
    assert content['provider_id'] == 'provider-a'
    assert docs[0].metadata.doc_id == 'doc-1'
    assert docs[0].id == 'chunk-1'
```

- [ ] **Step 3: Run the new tests to verify they fail**

Run: `pytest agents/tests/test_retrieval_service.py agents/tests/test_seraph_knowledge.py -v`
Expected: FAIL because the retrieval and knowledge modules do not exist.

- [ ] **Step 4: Add retrieval repository and result types**

Create `agents/retrieval/repository.py` with a result type and query shape:

```python
from dataclasses import dataclass
from typing import Protocol


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
    async def search(self, embedding: list[float], scopes: list[tuple[str, str]], limit: int) -> list[RetrievalResult]: ...
```

- [ ] **Step 5: Implement the retrieval service**

Create `agents/retrieval/service.py`:

```python
from collections.abc import Awaitable, Callable, Sequence
from typing import Protocol

from retrieval.repository import RetrievalRepository, RetrievalResult
from spaces.access import SpaceScope


class EmbeddingResponse(Protocol):
    embeddings: Sequence[Sequence[float]]


class RetrievalService:
    def __init__(self, embedder: Callable[[list[str]], Awaitable[EmbeddingResponse]], repo: RetrievalRepository) -> None:
        self._embedder = embedder
        self._repo = repo

    async def retrieve(self, query: str, scopes: list[SpaceScope], limit: int = 5) -> list[RetrievalResult]:
        embedding_response = await self._embedder([query])
        if not embedding_response.embeddings or not embedding_response.embeddings[0]:
            raise ValueError('missing query embedding')
        allowed_scopes = [(scope.provider_id, scope.path_prefix) for scope in scopes]
        return await self._repo.search(list(embedding_response.embeddings[0]), allowed_scopes, limit)
```

- [ ] **Step 6: Implement the custom AgentScope knowledge adapter**

Create `agents/knowledge/seraph_knowledge.py`:

```python
from dataclasses import dataclass, field

from agentscope.rag import KnowledgeBase
from agentscope.rag._document import Document, DocMetadata


@dataclass(frozen=True)
class SeraphChunkProvenance:
    provider_id: str
    path: str


@dataclass
class SeraphKnowledgeDocument(Document):
    provenance: SeraphChunkProvenance = field(default_factory=lambda: SeraphChunkProvenance(provider_id='', path=''))


class SeraphKnowledgeBase(KnowledgeBase):
    def __init__(self, embedding_store, embedding_model, retrieval_service, spaces_client, user_id: str) -> None:
        super().__init__(embedding_store=embedding_store, embedding_model=embedding_model)
        self._retrieval_service = retrieval_service
        self._spaces_client = spaces_client
        self._user_id = user_id

    async def retrieve(self, query: str, limit: int = 5, score_threshold: float | None = None, **kwargs) -> list[Document]:
        scopes = await self._spaces_client.get_scopes_for_user(self._user_id)
        results = await self._retrieval_service.retrieve(query=query, scopes=scopes, limit=limit)
        return [
            SeraphKnowledgeDocument(
                id=result.chunk_id,
                score=result.score,
                provenance=SeraphChunkProvenance(provider_id=result.provider_id, path=result.path),
                metadata=DocMetadata(
                    content={'type': 'text', 'text': result.content},
                    doc_id=result.document_id,
                    chunk_id=result.chunk_index,
                    total_chunks=result.total_chunks,
                ),
            )
            for result in results
            if score_threshold is None or result.score >= score_threshold
        ]

    async def add_documents(self, documents: list[Document], **kwargs) -> None:
        return None
```

- [ ] **Step 7: Implement the real spaces client contract**

Replace `agents/spaces/client.py` with a NATS-backed implementation that returns `SpaceScope` rows from Seraph spaces data, normalizes them to canonical `provider_id` + `path_prefix` pairs, deduplicates repeated scopes, and treats an explicit empty-string provider path as root `/`.

- [ ] **Step 8: Run the retrieval and knowledge tests**

Run: `pytest agents/tests/test_retrieval_service.py agents/tests/test_seraph_knowledge.py -v`
Expected: PASS

- [ ] **Step 9: Commit the retrieval slice**

```bash
git add agents/retrieval/repository.py agents/retrieval/service.py agents/knowledge/seraph_knowledge.py agents/spaces/client.py agents/tests/test_retrieval_service.py agents/tests/test_seraph_knowledge.py
git commit -m "feat: add spaces-aware retrieval for agentscope knowledge"
```

### Task 4.5: Add the Concrete Pgvector Retrieval Repository

**Files:**
- Modify: `agents/retrieval/repository.py`
- Test: `agents/tests/test_retrieval_repository.py`

- [ ] **Step 1: Write the failing repository integration test**

Add a Postgres-backed test that inserts indexed documents and chunks, then verifies:

- provider/path-prefix scope filtering
- root scope `/` handling
- real `chunk_index` / `total_chunks` are returned
- results are ranked by vector distance

- [ ] **Step 2: Run the repository test to verify it fails**

Run: `pytest agents/tests/test_retrieval_repository.py -v`
Expected: FAIL because the concrete pgvector repository does not exist yet.

- [ ] **Step 3: Replace the protocol-only repository with a concrete implementation**

Implement `PgVectorRetrievalRepository` in `agents/retrieval/repository.py` using the canonical Task 3 tables:

- join `documents` and `document_chunks`
- filter `documents.ingest_status == 'indexed'`
- skip chunks without embeddings
- constrain matches to allowed `(provider_id, path_prefix)` scopes
- treat root scope `/` as full-provider access
- return `RetrievalResult(document_id, chunk_id, chunk_index, total_chunks, provider_id, path, content, score)`

- [ ] **Step 4: Run repository and service tests**

Run: `pytest agents/tests/test_retrieval_service.py agents/tests/test_retrieval_repository.py -v`
Expected: PASS or SKIP only if Postgres/pgvector prerequisites are unavailable.

- [ ] **Step 5: Run lint and type checks**

Run: `ruff check agents/retrieval/repository.py agents/tests/test_retrieval_service.py agents/tests/test_retrieval_repository.py`
Expected: PASS

Run: `mypy --explicit-package-bases agents/retrieval/repository.py agents/tests/test_retrieval_service.py agents/tests/test_retrieval_repository.py`
Expected: PASS

- [ ] **Step 6: Commit the retrieval repository slice**

```bash
git add agents/retrieval/repository.py agents/tests/test_retrieval_repository.py
git commit -m "feat: add concrete pgvector retrieval repository"
```

### Task 5: Build the AgentScope Chat Runtime and FastAPI API Surface

**Files:**
- Create: `agents/api/models.py`
- Create: `agents/api/chat.py`
- Create: `agents/api/documents.py`
- Create: `agents/chat/agent_factory.py`
- Create: `agents/chat/prompts.py`
- Create: `agents/chat/streaming.py`
- Create: `agents/chat/citations.py`
- Modify: `agents/app/main.py`
- Modify: `agents/documents/models.py`
- Test: `agents/tests/test_chat_api.py`
- Test: `agents/tests/test_chat_streaming.py`

Task 5 also needs a minimal durable pending-turn handoff so `POST /messages` and `GET /stream` are connected without relying on process-local memory. Use a small `PendingChatTurn` table in `agents/documents/models.py` for this slice.

- [ ] **Step 1: Write the failing session-list API test**

```python
from fastapi.testclient import TestClient

from app.main import create_app


def test_list_sessions_requires_authenticated_user() -> None:
    client = TestClient(create_app())

    response = client.get('/api/v1/chat/sessions')

    assert response.status_code == 401
```

- [ ] **Step 2: Write the failing SSE chat test**

```python
from fastapi.testclient import TestClient

from app.main import create_app


def test_message_stream_returns_sse_payload() -> None:
    client = TestClient(create_app())

    with client.stream('GET', '/api/v1/chat/sessions/session-1/stream', headers={'X-Seraph-User': 'alice'}) as response:
        assert response.status_code == 200
        first_chunk = next(response.iter_text())
        assert 'data:' in first_chunk
```

- [ ] **Step 3: Run the API tests to verify they fail**

Run: `pytest agents/tests/test_chat_api.py agents/tests/test_chat_streaming.py -v`
Expected: FAIL because the chat routers and streaming handlers do not exist.

- [ ] **Step 4: Build the AgentScope agent factory**

Create `agents/chat/agent_factory.py`:

```python
from agentscope.agent import ReActAgent
from agentscope.formatter import OpenAIChatFormatter
from agentscope.memory import AsyncSQLAlchemyMemory
from agentscope.model import OpenAIChatModel
from agentscope.tool import Toolkit

from chat.prompts import DOCUMENT_CHAT_PROMPT
from knowledge.seraph_knowledge import SeraphKnowledgeBase


class AgentFactory:
    def __init__(self, engine, chat_model_name: str, api_key: str | None, base_url: str | None, embedding_model, retrieval_service, spaces_client) -> None:
        self._engine = engine
        self._chat_model_name = chat_model_name
        self._api_key = api_key
        self._base_url = base_url
        self._embedding_model = embedding_model
        self._retrieval_service = retrieval_service
        self._spaces_client = spaces_client

    def create(self, user_id: str, session_id: str) -> ReActAgent:
        return ReActAgent(
            name='seraph-documents',
            sys_prompt=DOCUMENT_CHAT_PROMPT,
            model=OpenAIChatModel(model_name=self._chat_model_name, api_key=self._api_key, client_kwargs={'base_url': self._base_url} if self._base_url else None, stream=True),
            formatter=OpenAIChatFormatter(),
            toolkit=Toolkit(),
            memory=AsyncSQLAlchemyMemory(self._engine, session_id=session_id, user_id=user_id),
            knowledge=SeraphKnowledgeBase(embedding_store=None, embedding_model=self._embedding_model, retrieval_service=self._retrieval_service, spaces_client=self._spaces_client, user_id=user_id),
            enable_rewrite_query=False,
        )
```

Create `agents/chat/prompts.py`:

```python
DOCUMENT_CHAT_PROMPT = """You are Seraph's document assistant.

Use retrieved document context first.
Only answer with information supported by retrieved content.
When you use document context, cite the file path.
If relevant information is not available in the retrieved content, say so clearly.
"""
```

- [ ] **Step 5: Build the SSE adapter and citation persistence helpers**

Create `agents/chat/streaming.py`:

```python
import json
from collections.abc import AsyncGenerator

from agentscope.pipeline import stream_printing_messages
from agentscope.message import Msg


async def stream_agent_reply(agent, user_input: str) -> AsyncGenerator[str, None]:
    async for msg, _ in stream_printing_messages(agents=[agent], coroutine_task=agent(Msg('user', user_input, 'user'))):
        yield f"data: {json.dumps(msg.to_dict(), ensure_ascii=False)}\n\n"
```

- [ ] **Step 6: Add the API routers and wire them into `app/main.py`**

Create `agents/api/chat.py` with endpoints of this shape:

```python
router = APIRouter(prefix='/api/v1/chat', tags=['chat'])


@router.get('/sessions')
async def list_sessions(user: AuthenticatedUser = Depends(get_current_user), db: AsyncSession = Depends(get_db_session)):
    service = SessionService(db)
    return [SessionResponse.model_validate(session) for session in await service.list_sessions(user.user_id)]


@router.post('/sessions/{session_id}/messages')
async def create_message(...):
    # Persist a new pending turn for this session/user.
    return {'accepted': True}


@router.get('/sessions/{session_id}/stream')
async def stream_message(...):
    # Claim the oldest pending turn for this session/user and stream it.
    return StreamingResponse(stream_agent_reply(agent, pending_turn.message), media_type='text/event-stream')
```

and update `app/main.py` to `include_router(chat.router)` and `include_router(documents.router)`.

- [ ] **Step 7: Add citation and failure models**

Extend `agents/documents/models.py` with:

- `ChatTurnSource` rows keyed by `session_id` and `assistant_message_id`, with a uniqueness constraint on `(session_id, assistant_message_id, provider_id, path)` so repeated streamed citation updates cannot insert duplicates.
- `ChatTurnFailure` rows that store assistant-side generation failures.
- `PendingChatTurn` rows that durably queue accepted user turns between `POST /messages` and `GET /stream`.

For this slice, source persistence should come from the real runtime provenance already present on `SeraphKnowledgeDocument` values returned by the knowledge layer, not from an assumed top-level `citations` field in streamed agent payloads.

- [ ] **Step 8: Run the chat API tests**

Run: `pytest agents/tests/test_chat_api.py agents/tests/test_chat_streaming.py -v`
Expected: PASS

- [ ] **Step 9: Run ruff and mypy on the new API/runtime files**

Run: `ruff check agents/api agents/chat agents/knowledge`
Expected: PASS

Run: `mypy agents/api agents/chat agents/knowledge`
Expected: PASS

- [ ] **Step 10: Commit the chat runtime slice**

```bash
git add agents/api/models.py agents/api/chat.py agents/api/documents.py agents/chat/agent_factory.py agents/chat/streaming.py agents/chat/citations.py agents/app/main.py agents/documents/models.py agents/tests/test_chat_api.py agents/tests/test_chat_streaming.py
git commit -m "feat: add agentscope chat api and streaming runtime"
```

### Task 6: Add the Minimal SPA Served by FastAPI

**Files:**
- Create: `agents/ui/package.json`
- Create: `agents/ui/tsconfig.json`
- Create: `agents/ui/index.html`
- Create: `agents/ui/src/main.ts`
- Create: `agents/ui/src/api.ts`
- Create: `agents/ui/src/app.ts`
- Modify: `agents/app/main.py`
- Test: `agents/tests/test_ui_static.py`

- [ ] **Step 1: Write the failing static UI test**

```python
from fastapi.testclient import TestClient

from app.main import create_app


def test_root_serves_chat_ui() -> None:
    client = TestClient(create_app())

    response = client.get('/')

    assert response.status_code == 200
    assert 'Seraph Chat' in response.text
```

- [ ] **Step 2: Run the UI test to verify it fails**

Run: `pytest agents/tests/test_ui_static.py -v`
Expected: FAIL because no UI assets are mounted.

- [ ] **Step 3: Add a minimal SPA toolchain**

Create `agents/ui/package.json`:

```json
{
  "name": "seraph-agents-ui",
  "private": true,
  "scripts": {
    "build": "esbuild src/main.ts --bundle --outfile=dist/app.js --format=esm"
  },
  "devDependencies": {
    "esbuild": "^0.25.0",
    "typescript": "^5.8.0"
  }
}
```

- [ ] **Step 4: Add the SPA entrypoint and API client**

Create `agents/ui/src/api.ts`:

```ts
export async function listSessions() {
  const response = await fetch('/api/v1/chat/sessions', { credentials: 'same-origin' })
  return response.json()
}

export async function createSession(title: string) {
  const response = await fetch('/api/v1/chat/sessions', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title })
  })
  return response.json()
}
```

Create `agents/ui/src/app.ts` with a plain TypeScript UI that renders a session list, a chat pane, and an `EventSource` connection to `/api/v1/chat/sessions/{sessionId}/stream`.

- [ ] **Step 5: Add the HTML shell**

Create `agents/ui/index.html`:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Seraph Chat</title>
  </head>
  <body>
    <div id="app"></div>
    <script type="module" src="/ui/app.js"></script>
  </body>
</html>
```

- [ ] **Step 6: Mount the built UI in FastAPI**

Update `agents/app/main.py` to serve `agents/ui/index.html` at `/` and static build output at `/ui` using `StaticFiles`.

- [ ] **Step 7: Build the SPA and run the UI test**

Run: `npm install`
Expected: installs `esbuild` and `typescript` in `agents/ui`

Run: `npm run build`
Expected: creates `agents/ui/dist/app.js`

Run: `pytest agents/tests/test_ui_static.py -v`
Expected: PASS

- [ ] **Step 8: Commit the UI slice**

```bash
git add agents/ui agents/app/main.py agents/tests/test_ui_static.py
git commit -m "feat: add minimal multi-session chat ui"
```

### Task 7: Remove Agno Leftovers and Run Full Verification

**Files:**
- Delete: `agents/agents/documents_agent.py`
- Delete: `agents/agents/knowledge_agent.py`
- Delete: `agents/agents/mcp_agent.py`
- Delete: `agents/agents/pal.py`
- Delete: `agents/knowledge/user_documents.py`
- Modify: `agents/README.md`
- Modify: `agents/scripts/venv_setup.sh`
- Test: `agents/tests/test_fileprovider_client_integration.py`
- Test: `agents/tests/test_ingestion_integration.py`
- Test: `agents/tests/test_chat_api.py`
- Test: `agents/tests/test_chat_streaming.py`

- [ ] **Step 1: Write the failing dependency cleanup test**

Create a simple regression test in `agents/tests/test_dependency_cleanup.py`:

```python
from pathlib import Path


def test_pyproject_no_longer_references_agno() -> None:
    pyproject = Path('agents/pyproject.toml').read_text(encoding='utf-8')

    assert 'agno' not in pyproject
    assert 'agentscope' in pyproject
```

- [ ] **Step 2: Run the cleanup test to verify it fails if any Agno references remain**

Run: `pytest agents/tests/test_dependency_cleanup.py -v`
Expected: PASS only after all Agno references are removed.

- [ ] **Step 3: Delete obsolete Agno agent modules**

Remove these files entirely:

```text
agents/agents/documents_agent.py
agents/agents/knowledge_agent.py
agents/agents/mcp_agent.py
agents/agents/pal.py
agents/knowledge/user_documents.py
```

- [ ] **Step 4: Update developer scripts and README**

In `agents/scripts/venv_setup.sh`, replace Agno-specific banner text with neutral `Seraph Agents` wording and ensure it still installs `-e .[dev]`.

In `agents/README.md`, rewrite the project description and local development steps around:

```text
- FastAPI app entrypoint
- AgentScope runtime
- canonical document indexing
- spaces-aware retrieval
- minimal SPA served by FastAPI
```

- [ ] **Step 5: Run the unit and integration suites**

Run: `pytest agents/tests/test_fileprovider_client_integration.py -v`
Expected: PASS

Run: `pytest agents/tests/test_ingestion_integration.py agents/tests/test_chat_api.py agents/tests/test_chat_streaming.py -v`
Expected: PASS or SKIP only where external prerequisites are unavailable.

- [ ] **Step 6: Run lint and type checks for the whole agents package**

Run: `ruff check agents`
Expected: PASS

Run: `mypy agents`
Expected: PASS

- [ ] **Step 7: Run Docker-based end-to-end verification**

Run: `docker compose -f agents/compose.yaml up -d --build`
Expected: `agents-db` and `agents-api` start successfully.

Run: `docker compose -f agents/compose.yaml ps`
Expected: both services show `running`.

Then verify manually:

```text
1. Open http://localhost:8000/
2. Create two chat sessions as the same authenticated user
3. Send messages in both sessions
4. Confirm streamed replies render incrementally
5. Confirm replies include citations for indexed documents
6. Confirm a user cannot read another user's chat session
7. Confirm a document outside the caller's accessible spaces is not cited or returned
```

- [ ] **Step 8: Commit the cleanup and verification slice**

```bash
git add agents/README.md agents/scripts/venv_setup.sh agents/tests/test_dependency_cleanup.py
git add -u agents/agents agents/knowledge
git commit -m "refactor: finish agentscope migration and remove agno"
```

## Self-Review Notes

- Spec coverage: the plan covers FastAPI bootstrap, AgentScope runtime, canonical indexing, spaces-based access control, SSE chat, SPA delivery, and cleanup of all Agno/AgentOS code.
- Placeholder scan: endpoint names, concrete file paths, test files, and commands are all explicit; no `TODO`/`TBD` placeholders remain.
- Type consistency: `AuthenticatedUser`, `SpaceScope`, `SessionService`, `RetrievalService`, `SeraphKnowledgeBase`, and `AgentFactory` names are used consistently across tasks.
