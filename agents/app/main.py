import asyncio
from contextlib import asynccontextmanager
import importlib
import logging
import os
from pathlib import Path
from typing import Any, Protocol, cast

from agentscope.model import OpenAIChatModel
from openai import AsyncOpenAI
from pydantic import BaseModel
import uvicorn
from fastapi import FastAPI, Response
from fastapi.responses import FileResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from nats.aio.client import Client as NatsClient

from app.otel import setup_telemetry
from app.settings import Settings, get_settings
from chat.agent_factory import AgentFactory
from chat.file_access import AgentFileAccessService
from chat.search_client import AgentSearchClient
from db.session import SessionLocal, engine
from documents.models import Base
from fileprovider.client import FileProviderClient
from retrieval.repository import PgVectorRetrievalRepository
from retrieval.service import RetrievalService
from spaces.client import SpacesClient


logger = logging.getLogger(__name__)
DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1"


def _normalize_openai_base_url(base_url: str | None) -> str | None:
    if base_url is None:
        return None
    normalized = base_url.strip()
    return normalized or None


class _EmbeddingResponseProtocol(Protocol):
    embeddings: list[list[float]]


class _EmbeddingResponse(_EmbeddingResponseProtocol):
    def __init__(self, embeddings: list[list[float]]) -> None:
        self.embeddings = embeddings


class _OpenAIEmbedder:
    def __init__(self, model_name: str, api_key: str | None, base_url: str | None) -> None:
        self._model_name = model_name
        self._api_key = api_key
        self._base_url = _normalize_openai_base_url(base_url)
        self._client: AsyncOpenAI | None = None

    def _get_client(self) -> AsyncOpenAI:
        if self._client is None:
            client_kwargs: dict[str, str | None] = {"api_key": self._api_key}
            client_kwargs["base_url"] = self._base_url or DEFAULT_OPENAI_BASE_URL
            self._client = AsyncOpenAI(**client_kwargs)
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


class _LazyNatsConnection:
    def __init__(self, nats_url: str) -> None:
        self._nats_url = nats_url
        self._nc: NatsClient | None = None
        self._lock = asyncio.Lock()

    async def get(self) -> NatsClient:
        if self._nc is None:
            async with self._lock:
                if self._nc is None:
                    self._nc = await self._connect_nats()
        return self._nc

    async def subscribe(self, subject: str):
        return await (await self.get()).subscribe(subject)

    async def publish(self, subject: str, payload: bytes) -> None:
        await (await self.get()).publish(subject, payload)

    async def _connect_nats(self) -> NatsClient:
        nc = NatsClient()
        await nc.connect(servers=[self._nats_url])
        return nc

    async def aclose(self) -> None:
        if self._nc is not None:
            await self._nc.close()
            self._nc = None


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
        openai_base_url = _normalize_openai_base_url(settings.openai_base_url)
        embedder = _OpenAIEmbedder(
            model_name=settings.embedding_model_name,
            api_key=settings.openai_api_key,
            base_url=openai_base_url,
        )
        self._spaces_client = _LazySpacesClient(settings.nats_url)
        self._nats = _LazyNatsConnection(settings.nats_url)
        self._factory = AgentFactory(
            engine=engine,
            chat_model_name=settings.chat_model_name,
            api_key=settings.openai_api_key,
            base_url=openai_base_url,
            embedding_model=embedder,
            retrieval_service=_LazyRetrievalService(embedder),
            spaces_client=self._spaces_client,
            search_client=None,
            file_access_service_factory=self._create_file_access_service,
        )

    def create(self, user_id: str, session_id: str):
        return self._factory.create(user_id, session_id)

    def _create_file_access_service(self, user_id: str) -> AgentFileAccessService:
        del user_id

        class _LazyFileProviderClient:
            def __init__(self, provider_id: str, nats_connection: _LazyNatsConnection) -> None:
                self._provider_id = provider_id
                self._nats_connection = nats_connection
                self._client: FileProviderClient | None = None

            async def _get_client(self) -> FileProviderClient:
                if self._client is None:
                    self._client = FileProviderClient(self._provider_id, await self._nats_connection.get())
                return self._client

            async def stat(self, path: str):
                return await (await self._get_client()).stat(path)

            async def open_file(self, path: str, flag: int, perm: int):
                return await (await self._get_client()).open_file(path, flag, perm)

        return AgentFileAccessService(
            spaces_client=self._spaces_client,
            file_provider_factory=lambda provider_id: _LazyFileProviderClient(provider_id, self._nats),
            search_client=AgentSearchClient(self._nats),
            max_read_bytes=int(os.getenv("SERAPH_AGENT_FILE_READ_BYTES", "131072")),
            max_inline_file_size=int(os.getenv("SERAPH_AGENT_FILE_MAX_SIZE", "262144")),
        )

    async def aclose(self) -> None:
        await self._spaces_client.aclose()
        await self._nats.aclose()


class _SessionTitleSummary(BaseModel):
    title: str


class RuntimeSessionTitleSummarizer:
    def __init__(self, settings: Settings) -> None:
        self._enabled = bool(settings.openai_api_key)
        self._model: OpenAIChatModel | None = None
        if not self._enabled:
            return
        client_kwargs: dict[str, str] = {
            "base_url": _normalize_openai_base_url(settings.openai_base_url) or DEFAULT_OPENAI_BASE_URL,
        }
        self._model = OpenAIChatModel(
            model_name=settings.chat_model_name,
            api_key=settings.openai_api_key,
            client_kwargs=client_kwargs,
            stream=False,
        )

    async def summarize(self, message: str) -> str:
        if not self._enabled or self._model is None:
            raise RuntimeError("session title summarizer is disabled")
        response = await self._model(
            [
                {
                    "role": "system",
                    "content": (
                        "Generate a concise conversation title for a chat sidebar. "
                        "Return 3 to 7 words, plain text, no quotes, no punctuation unless required."
                    ),
                },
                {"role": "user", "content": message},
            ],
            structured_model=_SessionTitleSummary,
        )
        metadata = response.metadata or {}
        title = metadata.get("title")
        if not isinstance(title, str):
            raise ValueError("title summary missing")
        return title.strip()


class _ManagedIngestionService:
    def __init__(self, service: Any) -> None:
        self._service = service

    async def start(self) -> None:
        await self._service.start()

    async def stop(self) -> None:
        await self._service.stop()


UI_DIR = Path(__file__).resolve().parents[1] / "ui"
UI_DIST_DIR = UI_DIR / "dist"
UI_INDEX_FILE = UI_DIST_DIR / "index.html"
DEFAULT_UI_DEV_SERVER_URL = "http://127.0.0.1:5173"


def create_ingestion_service(settings: Settings) -> Any:
    del settings
    module = importlib.import_module("ingestion.file_changed_consumer")
    build_ingestion_service = getattr(module, "create_ingestion_service")

    return _ManagedIngestionService(build_ingestion_service())


async def initialize_database_schema() -> None:
    sqlalchemy_memory = importlib.import_module("agentscope.memory._working_memory._sqlalchemy_memory")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        await conn.run_sync(sqlalchemy_memory.Base.metadata.create_all)


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.settings = get_settings()
    await initialize_database_schema()
    ingestion_service = create_ingestion_service(app.state.settings)
    app.state.ingestion_service = ingestion_service

    async def cleanup() -> None:
        cleanup_error: Exception | None = None

        try:
            await ingestion_service.stop()
        except Exception as exc:
            cleanup_error = exc

        close = getattr(app.state.agent_factory, "aclose", None)
        if close is not None:
            try:
                await close()
            except Exception:
                if cleanup_error is None:
                    raise

        if cleanup_error is not None:
            raise cleanup_error

    try:
        await ingestion_service.start()
    except Exception as start_error:
        try:
            await cleanup()
        except Exception:
            logger.exception("Cleanup failed after ingestion startup failure")
        raise start_error

    try:
        yield
    finally:
        await cleanup()


def create_app() -> FastAPI:
    chat_api = importlib.import_module("api.chat")
    documents_api = importlib.import_module("api.documents")
    settings = get_settings()

    app = FastAPI(title="Seraph Agents", lifespan=lifespan)
    setup_telemetry(app)
    app.state.agent_factory = RuntimeAgentFactory(settings)
    app.state.session_title_summarizer = RuntimeSessionTitleSummarizer(settings)
    app.state.spaces_client = app.state.agent_factory._spaces_client

    @app.get("/healthz")
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/")
    async def root() -> Response:
        if settings.runtime_env == "dev" and settings.ui_dev_server_url:
            return RedirectResponse(url="/ui-dev/", status_code=307)
        return FileResponse(UI_INDEX_FILE if UI_INDEX_FILE.exists() else (UI_DIR / "index.html"))

    if settings.runtime_env == "dev" and settings.ui_dev_server_url:
        ui_dev_module = importlib.import_module("api.ui_dev_proxy")
        app.mount(
            "/ui-dev",
            ui_dev_module.create_ui_dev_proxy(settings.ui_dev_server_url),
            name="ui-dev",
        )

    app.include_router(chat_api.router)
    app.include_router(documents_api.router)
    app.mount("/ui", StaticFiles(directory=UI_DIST_DIR if UI_DIST_DIR.exists() else UI_DIR), name="ui")

    return app


app = create_app()


def main() -> None:
    settings = get_settings()
    uvicorn.run("app.main:app", host=settings.app_host, port=settings.app_port, reload=settings.runtime_env == "dev")


if __name__ == "__main__":
    main()
