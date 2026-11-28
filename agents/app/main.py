import os
from collections.abc import AsyncIterator
from contextlib import AsyncExitStack, asynccontextmanager
from dataclasses import dataclass

import pydantic_ai
import uvicorn
from fastapi import FastAPI
from nats.aio.client import Client as NatsClient
from openai import AsyncOpenAI

from api import chat as chat_api
from api import documents as documents_api
from app.otel import setup_telemetry
from app.settings import Settings, get_settings
from chat.agent_factory import DEFAULT_OPENAI_BASE_URL, AgentFactory, build_chat_model
from chat.file_access import AgentFileAccessService
from chat.search_client import AgentSearchClient
from db.migrations import apply_migrations
from db.session import SessionLocal, engine
from documents.models import Base
from fileprovider.client import FileProviderClient
from fileprovider.nats_client import connect_nats_from_env
from ingestion.file_changed_consumer import create_ingestion_service
from retrieval.repository import PgVectorRetrievalRepository, RetrievalResult
from retrieval.service import RetrievalService
from spaces.access import SpaceScope
from spaces.client import SpacesClient


pydantic_ai.BANNER_ENABLED = False


@dataclass(frozen=True)
class _Embeddings:
    embeddings: list[list[float]]


class _OpenAIEmbedder:
    def __init__(self, settings: Settings) -> None:
        base_url = (settings.openai_base_url or "").strip() or DEFAULT_OPENAI_BASE_URL
        self._client = AsyncOpenAI(api_key=settings.openai_api_key, base_url=base_url)
        self._model_name = settings.embedding_model_name

    async def __call__(self, values: list[str]) -> _Embeddings:
        response = await self._client.embeddings.create(model=self._model_name, input=values)
        return _Embeddings(embeddings=[list(item.embedding) for item in response.data])


class _PgVectorRetrieval:
    """Retrieval with a fresh DB session per query, since tools run outside any request's session."""

    def __init__(self, embedder: _OpenAIEmbedder) -> None:
        self._embedder = embedder

    async def retrieve(self, query: str, scopes: list[SpaceScope], limit: int = 5) -> list[RetrievalResult]:
        async with SessionLocal() as session:
            service = RetrievalService(embedder=self._embedder, repo=PgVectorRetrievalRepository(session))
            return await service.retrieve(query=query, scopes=scopes, limit=limit)


def build_agent_factory(settings: Settings, nc: NatsClient) -> AgentFactory:
    spaces = SpacesClient(nc)
    file_providers: dict[str, FileProviderClient] = {}

    def file_provider(provider_id: str) -> FileProviderClient:
        if provider_id not in file_providers:
            file_providers[provider_id] = FileProviderClient(provider_id, nc)
        return file_providers[provider_id]

    file_access = AgentFileAccessService(
        spaces_client=spaces,
        file_provider_factory=file_provider,
        search_client=AgentSearchClient(nc),
        max_read_bytes=int(os.getenv("SERAPH_AGENT_FILE_READ_BYTES", "131072")),
        max_inline_file_size=int(os.getenv("SERAPH_AGENT_FILE_MAX_SIZE", "262144")),
    )
    return AgentFactory(
        model=build_chat_model(settings.chat_model_name, settings.openai_api_key, settings.openai_base_url),
        retrieval_service=_PgVectorRetrieval(_OpenAIEmbedder(settings)),
        spaces_client=spaces,
        file_access=file_access,
    )


async def initialize_database_schema() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await apply_migrations(conn)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings: Settings = app.state.settings
    await initialize_database_schema()
    async with AsyncExitStack() as stack:
        nc = await connect_nats_from_env()
        stack.push_async_callback(nc.close)
        app.state.spaces_client = SpacesClient(nc)
        app.state.agent_factory = build_agent_factory(settings, nc)

        ingestion = create_ingestion_service()
        stack.push_async_callback(ingestion.stop)
        await ingestion.start()
        yield


def create_app(settings: Settings | None = None) -> FastAPI:
    app = FastAPI(title="Seraph Agents", lifespan=lifespan)
    app.state.settings = settings or get_settings()
    setup_telemetry(app)

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    app.include_router(chat_api.router)
    app.include_router(documents_api.router)
    return app


app = create_app()


def main() -> None:
    settings = get_settings()
    uvicorn.run("app.main:app", host=settings.app_host, port=settings.app_port, reload=settings.runtime_env == "dev")


if __name__ == "__main__":
    main()
