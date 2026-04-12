import asyncio
from contextlib import asynccontextmanager
import importlib
from pathlib import Path
from typing import Any, Protocol, cast

from openai import AsyncOpenAI
import uvicorn
from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from nats.aio.client import Client as NatsClient

from app.otel import setup_telemetry
from app.settings import Settings, get_settings
from chat.agent_factory import AgentFactory
from db.session import SessionLocal, engine
from retrieval.repository import PgVectorRetrievalRepository
from retrieval.service import RetrievalService
from spaces.client import SpacesClient


class _EmbeddingResponseProtocol(Protocol):
    embeddings: list[list[float]]


class _EmbeddingResponse(_EmbeddingResponseProtocol):
    def __init__(self, embeddings: list[list[float]]) -> None:
        self.embeddings = embeddings


class _OpenAIEmbedder:
    def __init__(self, model_name: str, api_key: str | None, base_url: str | None) -> None:
        self._model_name = model_name
        self._api_key = api_key
        self._base_url = base_url
        self._client: AsyncOpenAI | None = None

    def _get_client(self) -> AsyncOpenAI:
        if self._client is None:
            self._client = AsyncOpenAI(api_key=self._api_key, base_url=self._base_url)
        return self._client

    async def __call__(self, values: list[str]) -> _EmbeddingResponse:
        response = await self._get_client().embeddings.create(model=self._model_name, input=values)
        return _EmbeddingResponse(embeddings=[list(item.embedding) for item in response.data])


class _LazySpacesClient:
    def __init__(self, nats_url: str) -> None:
        self._nats_url = nats_url
        self._nc: NatsClient | None = None
        self._client: SpacesClient | None = None
        self._lock = asyncio.Lock()

    async def get_scopes_for_user(self, user_id: str) -> list[Any]:
        if self._client is None:
            async with self._lock:
                if self._client is None:
                    self._nc = await self._connect_nats()
                    self._client = SpacesClient(self._nc)
        return await self._client.get_scopes_for_user(user_id)

    async def _connect_nats(self) -> NatsClient:
        nc = NatsClient()
        await nc.connect(servers=[self._nats_url])
        return nc

    async def aclose(self) -> None:
        if self._nc is not None:
            await self._nc.close()
            self._nc = None
            self._client = None


class _LazyRetrievalService:
    def __init__(self, embedder: _OpenAIEmbedder) -> None:
        self._embedder = embedder

    async def retrieve(self, query: str, scopes: list[Any], limit: int = 5):
        async with SessionLocal() as session:
            repo = PgVectorRetrievalRepository(session)
            service = RetrievalService(
                embedder=cast(Any, self._embedder),
                repo=repo,
            )
            return await service.retrieve(query=query, scopes=scopes, limit=limit)


class RuntimeAgentFactory:
    def __init__(self, settings: Settings) -> None:
        embedder = _OpenAIEmbedder(
            model_name=settings.embedding_model_name,
            api_key=settings.openai_api_key,
            base_url=settings.openai_base_url,
        )
        self._spaces_client = _LazySpacesClient(settings.nats_url)
        self._factory = AgentFactory(
            engine=engine,
            chat_model_name=settings.chat_model_name,
            api_key=settings.openai_api_key,
            base_url=settings.openai_base_url,
            embedding_model=embedder,
            retrieval_service=_LazyRetrievalService(embedder),
            spaces_client=self._spaces_client,
        )

    def create(self, user_id: str, session_id: str):
        return self._factory.create(user_id, session_id)

    async def aclose(self) -> None:
        await self._spaces_client.aclose()


class _ManagedIngestionService:
    def __init__(self, service: Any) -> None:
        self._service = service
        self._start_task: asyncio.Task[None] | None = None

    async def start(self) -> None:
        if self._start_task is None:
            self._start_task = asyncio.create_task(self._service.start())

    async def stop(self) -> None:
        if self._start_task is not None:
            if not self._start_task.done():
                self._start_task.cancel()
            await asyncio.gather(self._start_task, return_exceptions=True)
            self._start_task = None
        await self._service.stop()


UI_DIR = Path(__file__).resolve().parents[1] / "ui"
UI_DIST_DIR = UI_DIR / "dist"
UI_INDEX_FILE = UI_DIR / "index.html"


def create_ingestion_service(settings: Settings) -> Any:
    del settings
    module = importlib.import_module("ingestion.file_changed_consumer")
    build_ingestion_service = getattr(module, "create_ingestion_service")

    return _ManagedIngestionService(build_ingestion_service())


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.settings = get_settings()
    ingestion_service = create_ingestion_service(app.state.settings)
    app.state.ingestion_service = ingestion_service
    await ingestion_service.start()
    try:
        yield
    finally:
        await ingestion_service.stop()
        close = getattr(app.state.agent_factory, "aclose", None)
        if close is not None:
            await close()


def create_app() -> FastAPI:
    chat_api = importlib.import_module("api.chat")
    documents_api = importlib.import_module("api.documents")
    settings = get_settings()

    app = FastAPI(title="Seraph Agents", lifespan=lifespan)
    setup_telemetry(app)
    app.state.agent_factory = RuntimeAgentFactory(settings)
    app.state.spaces_client = app.state.agent_factory._spaces_client

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/")
    async def root() -> FileResponse:
        return FileResponse(UI_INDEX_FILE)

    app.include_router(chat_api.router)
    app.include_router(documents_api.router)
    app.mount("/ui", StaticFiles(directory=UI_DIST_DIR), name="ui")

    return app


app = create_app()


def main() -> None:
    settings = get_settings()
    uvicorn.run("app.main:app", host=settings.app_host, port=settings.app_port, reload=settings.runtime_env == "dev")


if __name__ == "__main__":
    main()
