import importlib
import sys
from pathlib import Path

from agentscope.tool import ToolResponse
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
        def __init__(self, label: str) -> None:
            self._label = label

        def create_all(self, bind):
            calls.append(f"create_all:{self._label}:{bind}")

    class StubIngestionService:
        async def start(self) -> None:
            calls.append("ingestion_start")

        async def stop(self) -> None:
            calls.append("ingestion_stop")

    class StubAgentScopeBase:
        metadata = DummyMetadata("agentscope")

    class StubAgentScopeModule:
        Base = StubAgentScopeBase

    original_import_module = importlib.import_module

    def fake_import_module(name: str):
        if name == "agentscope.memory._working_memory._sqlalchemy_memory":
            return StubAgentScopeModule
        return original_import_module(name)

    monkeypatch.setattr(app_main, "engine", DummyEngine())
    monkeypatch.setattr(app_main, "create_ingestion_service", lambda settings: StubIngestionService())
    monkeypatch.setattr(app_main.Base, "metadata", DummyMetadata("documents"))
    monkeypatch.setattr(importlib, "import_module", fake_import_module)

    app = app_main.create_app()
    with TestClient(app):
        pass

    assert calls == [
        "begin",
        "run_sync",
        "create_all:documents:sync-conn",
        "run_sync",
        "create_all:agentscope:sync-conn",
        "end",
        "ingestion_start",
        "ingestion_stop",
    ]


def test_app_startup_initializes_agentscope_database_schema(monkeypatch: pytest.MonkeyPatch) -> None:
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
        def __init__(self, label: str) -> None:
            self._label = label

        def create_all(self, bind):
            calls.append(f"create_all:{self._label}:{bind}")

    class StubIngestionService:
        async def start(self) -> None:
            calls.append("ingestion_start")

        async def stop(self) -> None:
            calls.append("ingestion_stop")

    class StubAgentScopeBase:
        metadata = DummyMetadata("agentscope")

    class StubAgentScopeModule:
        Base = StubAgentScopeBase

    original_import_module = importlib.import_module

    def fake_import_module(name: str):
        if name == "agentscope.memory._working_memory._sqlalchemy_memory":
            return StubAgentScopeModule
        return original_import_module(name)

    monkeypatch.setattr(app_main, "engine", DummyEngine())
    monkeypatch.setattr(app_main, "create_ingestion_service", lambda settings: StubIngestionService())
    monkeypatch.setattr(app_main.Base, "metadata", DummyMetadata("documents"))
    monkeypatch.setattr(importlib, "import_module", fake_import_module)

    app = app_main.create_app()
    with TestClient(app):
        pass

    assert calls == [
        "begin",
        "run_sync",
        "create_all:documents:sync-conn",
        "run_sync",
        "create_all:agentscope:sync-conn",
        "end",
        "ingestion_start",
        "ingestion_stop",
    ]


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


def test_agent_factory_registers_read_only_file_tools(monkeypatch: pytest.MonkeyPatch) -> None:
    module = importlib.import_module("chat.agent_factory")
    recorded: dict[str, object] = {}

    class StubOpenAIChatModel:
        def __init__(self, **kwargs: object) -> None:
            recorded["model_kwargs"] = kwargs

    class StubToolkit:
        def __init__(self) -> None:
            self.tools = []

        def register_tool_function(self, tool_func, **kwargs):
            self.tools.append({"tool_func": tool_func, **kwargs})

    class StubAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    monkeypatch.setattr(module, "OpenAIChatModel", StubOpenAIChatModel)
    monkeypatch.setattr(module, "Toolkit", StubToolkit)
    monkeypatch.setattr(module, "ReActAgent", StubAgent)
    monkeypatch.setattr(module, "AsyncSQLAlchemyMemory", lambda *args, **kwargs: object())
    monkeypatch.setattr(module, "OpenAIChatFormatter", lambda: object())
    monkeypatch.setattr(module, "SeraphKnowledgeBase", lambda **kwargs: object())

    class StubFileAccessService:
        async def search_files(self, query: str):
            del query
            return []

        async def list_directory(self, provider_id: str, path: str):
            del provider_id, path
            return []

        async def stat_file(self, provider_id: str, path: str):
            del provider_id, path
            return None

        async def read_file_excerpt(
            self,
            provider_id: str,
            path: str,
            start_line: int = 1,
            max_lines: int = 80,
            max_chars: int = 12000,
        ):
            del provider_id, path, start_line, max_lines, max_chars
            return None

    factory = module.AgentFactory(
        engine=object(),
        chat_model_name="gpt-test",
        api_key=None,
        base_url=None,
        embedding_model=object(),
        retrieval_service=object(),
        spaces_client=object(),
        search_client=object(),
        file_access_service_factory=lambda user_id: StubFileAccessService(),
    )

    factory.create("alice", "session-1")

    toolkit = recorded["toolkit"]
    assert len(toolkit.tools) == 4
    assert [tool["func_name"] for tool in toolkit.tools] == [
        "search_files",
        "list_directory",
        "stat_file",
        "read_file_excerpt",
    ]
    assert all(tool["async_execution"] is False for tool in toolkit.tools)


@pytest.mark.asyncio
async def test_agent_factory_file_tools_return_tool_responses(monkeypatch: pytest.MonkeyPatch) -> None:
    module = importlib.import_module("chat.agent_factory")
    recorded: dict[str, object] = {}

    class StubOpenAIChatModel:
        def __init__(self, **kwargs: object) -> None:
            recorded["model_kwargs"] = kwargs

    class StubToolkit:
        def __init__(self) -> None:
            self.tools = []

        def register_tool_function(self, tool_func, **kwargs):
            self.tools.append({"tool_func": tool_func, **kwargs})

    class StubAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    monkeypatch.setattr(module, "OpenAIChatModel", StubOpenAIChatModel)
    monkeypatch.setattr(module, "Toolkit", StubToolkit)
    monkeypatch.setattr(module, "ReActAgent", StubAgent)
    monkeypatch.setattr(module, "AsyncSQLAlchemyMemory", lambda *args, **kwargs: object())
    monkeypatch.setattr(module, "OpenAIChatFormatter", lambda: object())
    monkeypatch.setattr(module, "SeraphKnowledgeBase", lambda **kwargs: object())

    class StubFileAccessService:
        async def search_files(self, *, user_id: str, query: str):
            del user_id, query
            return [{"provider_id": "space-a", "path": "/team/spec.md", "label": "/team/spec.md"}]

        async def list_directory(self, *, user_id: str, provider_id: str, path: str):
            del user_id, provider_id, path
            return [{"path": "/team/spec.md", "is_dir": False}]

        async def stat_file(self, *, user_id: str, provider_id: str, path: str):
            del user_id, provider_id, path
            return {"path": "/team/spec.md", "size": 12, "is_dir": False}

        async def read_file_excerpt(
            self,
            *,
            user_id: str,
            provider_id: str,
            path: str,
            start_line: int = 1,
            max_lines: int = 80,
            max_chars: int = 12000,
        ):
            del user_id, provider_id, path, start_line, max_lines, max_chars
            return {"content": "hello", "start_line": 1, "end_line": 1, "truncated": False}

    factory = module.AgentFactory(
        engine=object(),
        chat_model_name="gpt-test",
        api_key=None,
        base_url=None,
        embedding_model=object(),
        retrieval_service=object(),
        spaces_client=object(),
        search_client=object(),
        file_access_service_factory=lambda user_id: StubFileAccessService(),
    )

    factory.create("alice", "session-1")

    toolkit = recorded["toolkit"]
    responses = []
    for tool in toolkit.tools:
        func = tool["tool_func"]
        if tool["func_name"] == "search_files":
            responses.append(await func("spec"))
        elif tool["func_name"] == "list_directory":
            responses.append(await func("space-a", "/team"))
        elif tool["func_name"] == "stat_file":
            responses.append(await func("space-a", "/team/spec.md"))
        else:
            responses.append(await func("space-a", "/team/spec.md"))

    assert all(isinstance(response, ToolResponse) for response in responses)
    assert [tool["func_name"] for tool in toolkit.tools] == [
        "search_files",
        "list_directory",
        "stat_file",
        "read_file_excerpt",
    ]


@pytest.mark.asyncio
async def test_agent_factory_file_tools_capture_tool_citations(monkeypatch: pytest.MonkeyPatch) -> None:
    module = importlib.import_module("chat.agent_factory")
    recorded: dict[str, object] = {}

    class StubOpenAIChatModel:
        def __init__(self, **kwargs: object) -> None:
            recorded["model_kwargs"] = kwargs

    class StubToolkit:
        def __init__(self) -> None:
            self.tools = []

        def register_tool_function(self, tool_func, **kwargs):
            self.tools.append({"tool_func": tool_func, **kwargs})

    class StubAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)
            recorded["agent"] = self

    monkeypatch.setattr(module, "OpenAIChatModel", StubOpenAIChatModel)
    monkeypatch.setattr(module, "Toolkit", StubToolkit)
    monkeypatch.setattr(module, "ReActAgent", StubAgent)
    monkeypatch.setattr(module, "AsyncSQLAlchemyMemory", lambda *args, **kwargs: object())
    monkeypatch.setattr(module, "OpenAIChatFormatter", lambda: object())
    monkeypatch.setattr(module, "SeraphKnowledgeBase", lambda **kwargs: object())

    class StubFileAccessService:
        async def search_files(self, *, user_id: str, query: str):
            del user_id, query
            return [{"provider_id": "space-a", "path": "/search.md", "label": "/search.md"}]

        async def list_directory(self, *, user_id: str, provider_id: str, path: str):
            del user_id, provider_id, path
            return [{"provider_id": "space-a", "path": "/listed.md", "is_dir": False}]

        async def stat_file(self, *, user_id: str, provider_id: str, path: str):
            del user_id, provider_id, path
            return {"provider_id": "space-a", "path": "/stat.md", "size": 12, "is_dir": False}

        async def read_file_excerpt(
            self,
            *,
            user_id: str,
            provider_id: str,
            path: str,
            start_line: int = 1,
            max_lines: int = 80,
            max_chars: int = 12000,
        ):
            del user_id, provider_id, path, start_line, max_lines, max_chars
            return {
                "reference": {"provider_id": "space-a", "path": "/excerpt.md", "label": "/excerpt.md"},
                "content": "hello",
                "start_line": 1,
                "end_line": 1,
                "truncated": False,
            }

    factory = module.AgentFactory(
        engine=object(),
        chat_model_name="gpt-test",
        api_key=None,
        base_url=None,
        embedding_model=object(),
        retrieval_service=object(),
        spaces_client=object(),
        search_client=object(),
        file_access_service_factory=lambda user_id: StubFileAccessService(),
    )

    factory.create("alice", "session-1")

    toolkit = recorded["toolkit"]
    agent = recorded["agent"]
    agent._seraph_tool_citations = []

    for tool in toolkit.tools:
        func = tool["tool_func"]
        if tool["func_name"] == "search_files":
            await func("spec")
        elif tool["func_name"] == "list_directory":
            await func("space-a", "/team")
        elif tool["func_name"] == "stat_file":
            await func("space-a", "/stat.md")
        else:
            await func("space-a", "/excerpt.md")

    assert agent._seraph_tool_citations == [
        {"provider_id": "space-a", "path": "/search.md", "label": "/search.md"},
        {"provider_id": "space-a", "path": "/listed.md", "label": "/listed.md"},
        {"provider_id": "space-a", "path": "/stat.md", "label": "/stat.md"},
        {"provider_id": "space-a", "path": "/excerpt.md", "label": "/excerpt.md"},
    ]


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
