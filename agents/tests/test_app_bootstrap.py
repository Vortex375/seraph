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
