import importlib
import sys
from pathlib import Path

from fastapi.testclient import TestClient
import pytest

sys.path.append(str(Path(__file__).resolve().parents[1]))

from app.main import create_app
from app.settings import Settings


def test_create_app_exposes_health_endpoint() -> None:
    app = create_app()

    with TestClient(app) as client:
        response = client.get("/healthz")

        assert response.status_code == 200
        assert response.json() == {"status": "ok"}
        assert isinstance(app.state.settings, Settings)


def test_app_startup_initializes_database_schema(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    calls: list[str] = []

    class DummyConn:
        async def run_sync(self, fn):
            calls.append("run_sync")
            fn("sync-conn")

    class DummyBegin:
        async def __aenter__(self):
            calls.append("begin")
            return DummyConn()

        async def __aexit__(self, exc_type, exc, tb):
            calls.append("end")

    class DummyEngine:
        def begin(self):
            return DummyBegin()

    class DummyMetadata:
        def create_all(self, bind):
            calls.append(f"create_all:{bind}")

    class StubIngestionService:
        async def start(self) -> None:
            calls.append("ingestion_start")

        async def stop(self) -> None:
            calls.append("ingestion_stop")

    monkeypatch.setattr(app_main, "engine", DummyEngine())
    monkeypatch.setattr(app_main, "create_ingestion_service", lambda settings: StubIngestionService())
    monkeypatch.setattr(importlib.import_module("documents.models").Base, "metadata", DummyMetadata())

    app = app_main.create_app()
    with TestClient(app):
        pass

    assert calls == ["begin", "run_sync", "create_all:sync-conn", "end", "ingestion_start", "ingestion_stop"]


def test_app_startup_failure_cleans_up_partial_resources(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    calls: list[str] = []

    class StubIngestionService:
        async def start(self) -> None:
            calls.append("ingestion_start")
            raise RuntimeError("ingestion startup failed")

        async def stop(self) -> None:
            calls.append("ingestion_stop")

    class StubAgentFactory:
        def __init__(self) -> None:
            self._spaces_client = object()

        async def aclose(self) -> None:
            calls.append("agent_factory_close")

    monkeypatch.setattr(app_main, "initialize_database_schema", lambda: __import__("asyncio").sleep(0))
    monkeypatch.setattr(app_main, "RuntimeAgentFactory", lambda settings: StubAgentFactory())
    monkeypatch.setattr(app_main, "create_ingestion_service", lambda settings: StubIngestionService())

    app = app_main.create_app()

    with pytest.raises(RuntimeError, match="ingestion startup failed"):
        with TestClient(app):
            pass

    assert calls == ["ingestion_start", "ingestion_stop", "agent_factory_close"]


def test_app_shutdown_closes_agent_factory(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    calls: list[str] = []

    class StubIngestionService:
        async def start(self) -> None:
            calls.append("ingestion_start")

        async def stop(self) -> None:
            calls.append("ingestion_stop")

    class StubAgentFactory:
        def __init__(self) -> None:
            self._spaces_client = object()

        async def aclose(self) -> None:
            calls.append("agent_factory_close")

    monkeypatch.setattr(app_main, "initialize_database_schema", lambda: __import__("asyncio").sleep(0))
    monkeypatch.setattr(app_main, "RuntimeAgentFactory", lambda settings: StubAgentFactory())
    monkeypatch.setattr(app_main, "create_ingestion_service", lambda settings: StubIngestionService())

    app = app_main.create_app()

    with TestClient(app):
        pass

    assert calls == ["ingestion_start", "ingestion_stop", "agent_factory_close"]


def test_app_shutdown_closes_agent_factory_when_ingestion_stop_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    calls: list[str] = []

    class StubIngestionService:
        async def start(self) -> None:
            calls.append("ingestion_start")

        async def stop(self) -> None:
            calls.append("ingestion_stop")
            raise RuntimeError("ingestion stop failed")

    class StubAgentFactory:
        def __init__(self) -> None:
            self._spaces_client = object()

        async def aclose(self) -> None:
            calls.append("agent_factory_close")

    monkeypatch.setattr(app_main, "initialize_database_schema", lambda: __import__("asyncio").sleep(0))
    monkeypatch.setattr(app_main, "RuntimeAgentFactory", lambda settings: StubAgentFactory())
    monkeypatch.setattr(app_main, "create_ingestion_service", lambda settings: StubIngestionService())

    app = app_main.create_app()

    with pytest.raises(RuntimeError, match="ingestion stop failed"):
        with TestClient(app):
            pass

    assert calls == ["ingestion_start", "ingestion_stop", "agent_factory_close"]


def test_app_startup_failure_remains_visible_when_cleanup_stop_fails(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    calls: list[str] = []

    class StubIngestionService:
        async def start(self) -> None:
            calls.append("ingestion_start")
            raise RuntimeError("ingestion startup failed")

        async def stop(self) -> None:
            calls.append("ingestion_stop")
            raise RuntimeError("ingestion stop failed")

    class StubAgentFactory:
        def __init__(self) -> None:
            self._spaces_client = object()

        async def aclose(self) -> None:
            calls.append("agent_factory_close")

    monkeypatch.setattr(app_main, "initialize_database_schema", lambda: __import__("asyncio").sleep(0))
    monkeypatch.setattr(app_main, "RuntimeAgentFactory", lambda settings: StubAgentFactory())
    monkeypatch.setattr(app_main, "create_ingestion_service", lambda settings: StubIngestionService())

    app = app_main.create_app()

    with pytest.raises(RuntimeError, match="ingestion startup failed"):
        with TestClient(app):
            pass

    assert calls == ["ingestion_start", "ingestion_stop", "agent_factory_close"]


def test_app_shutdown_raises_agent_factory_close_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    calls: list[str] = []

    class StubIngestionService:
        async def start(self) -> None:
            calls.append("ingestion_start")

        async def stop(self) -> None:
            calls.append("ingestion_stop")

    class StubAgentFactory:
        def __init__(self) -> None:
            self._spaces_client = object()

        async def aclose(self) -> None:
            calls.append("agent_factory_close")
            raise RuntimeError("agent factory close failed")

    monkeypatch.setattr(app_main, "initialize_database_schema", lambda: __import__("asyncio").sleep(0))
    monkeypatch.setattr(app_main, "RuntimeAgentFactory", lambda settings: StubAgentFactory())
    monkeypatch.setattr(app_main, "create_ingestion_service", lambda settings: StubIngestionService())

    app = app_main.create_app()

    with pytest.raises(RuntimeError, match="agent factory close failed"):
        with TestClient(app):
            pass

    assert calls == ["ingestion_start", "ingestion_stop", "agent_factory_close"]


def test_openai_embedder_normalizes_blank_base_url(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    recorded: dict[str, object] = {}

    class StubAsyncOpenAI:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    monkeypatch.setattr(app_main, "AsyncOpenAI", StubAsyncOpenAI)

    embedder = app_main._OpenAIEmbedder(
        model_name="text-embedding-3-small",
        api_key="test-key",
        base_url="",
    )

    embedder._get_client()

    assert recorded == {"api_key": "test-key", "base_url": "https://api.openai.com/v1"}


def test_runtime_agent_factory_normalizes_blank_base_url(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    recorded: dict[str, object] = {}

    class StubAgentFactory:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    monkeypatch.setattr(app_main, "AgentFactory", StubAgentFactory)

    settings = Settings(openai_api_key="test-key", openai_base_url="")

    app_main.RuntimeAgentFactory(settings)

    assert recorded["api_key"] == "test-key"
    assert recorded["base_url"] is None


def test_openai_embedder_uses_default_base_url_when_env_is_blank(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    recorded: dict[str, object] = {}

    class StubAsyncOpenAI:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    monkeypatch.setattr(app_main, "AsyncOpenAI", StubAsyncOpenAI)
    monkeypatch.setenv("OPENAI_BASE_URL", "")

    embedder = app_main._OpenAIEmbedder(
        model_name="text-embedding-3-small",
        api_key="test-key",
        base_url=None,
    )

    embedder._get_client()

    assert recorded == {"api_key": "test-key", "base_url": "https://api.openai.com/v1"}


def test_openai_embedder_treats_whitespace_only_base_url_as_blank(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    recorded: dict[str, object] = {}

    class StubAsyncOpenAI:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    monkeypatch.setattr(app_main, "AsyncOpenAI", StubAsyncOpenAI)

    embedder = app_main._OpenAIEmbedder(
        model_name="text-embedding-3-small",
        api_key="test-key",
        base_url="   ",
    )

    embedder._get_client()

    assert recorded == {"api_key": "test-key", "base_url": "https://api.openai.com/v1"}


def test_runtime_agent_factory_treats_whitespace_only_base_url_as_blank(monkeypatch: pytest.MonkeyPatch) -> None:
    app_main = importlib.import_module("app.main")
    recorded: dict[str, object] = {}

    class StubAgentFactory:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    monkeypatch.setattr(app_main, "AgentFactory", StubAgentFactory)

    settings = Settings(openai_api_key="test-key", openai_base_url="   ")

    app_main.RuntimeAgentFactory(settings)

    assert recorded["api_key"] == "test-key"
    assert recorded["base_url"] is None


def test_ingestion_service_embedder_normalizes_blank_base_url(monkeypatch: pytest.MonkeyPatch) -> None:
    consumer_module = importlib.import_module("ingestion.file_changed_consumer")
    recorded: dict[str, object] = {}

    class StubAsyncOpenAI:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    monkeypatch.setattr(consumer_module, "AsyncOpenAI", StubAsyncOpenAI)
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    monkeypatch.setenv("OPENAI_BASE_URL", "")
    monkeypatch.setenv("EMBEDDING_MODEL_NAME", "text-embedding-3-small")

    service = consumer_module.create_ingestion_service()
    service._get_embedding_client()

    assert recorded == {"api_key": "test-key", "base_url": "https://api.openai.com/v1"}
