import importlib
import sys
from pathlib import Path
from typing import Any

import pytest

sys.path.append(str(Path(__file__).resolve().parents[1]))


def test_agent_factory_uses_default_openai_base_url_when_blank(monkeypatch: pytest.MonkeyPatch) -> None:
    agent_factory_module = importlib.import_module("chat.agent_factory")
    recorded: dict[str, Any] = {}

    class StubCredential:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    class StubOpenAIChatModel:
        def __init__(self, **kwargs: object) -> None:
            recorded["model_kwargs"] = kwargs

    class StubToolkit:
        def __init__(self, tools: list[object] | None = None) -> None:
            self.tools = tools or []

    class StubAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded["agent_kwargs"] = kwargs

    monkeypatch.setattr(agent_factory_module, "OpenAICredential", StubCredential)
    monkeypatch.setattr(agent_factory_module, "OpenAIChatModel", StubOpenAIChatModel)
    monkeypatch.setattr(agent_factory_module, "Toolkit", StubToolkit)
    monkeypatch.setattr(agent_factory_module, "Agent", StubAgent)
    monkeypatch.setattr(agent_factory_module, "SeraphKnowledgeBase", lambda **kwargs: object())

    factory = agent_factory_module.AgentFactory(
        chat_model_name="gpt-5.4",
        api_key="test-key",
        base_url=None,
        retrieval_service=object(),
        spaces_client=object(),
    )

    factory.create(user_id="alice", session_id="session-1")

    assert recorded["api_key"] == "test-key"
    assert recorded["base_url"] == "https://api.openai.com/v1"
    assert recorded["model_kwargs"]["model"] == "gpt-5.4"


def test_agent_factory_uses_default_openai_base_url_when_whitespace_only(monkeypatch: pytest.MonkeyPatch) -> None:
    agent_factory_module = importlib.import_module("chat.agent_factory")
    recorded: dict[str, Any] = {}

    class StubCredential:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    class StubOpenAIChatModel:
        def __init__(self, **kwargs: object) -> None:
            recorded["model_kwargs"] = kwargs

    class StubToolkit:
        def __init__(self, tools: list[object] | None = None) -> None:
            self.tools = tools or []

    class StubAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded["agent_kwargs"] = kwargs

    monkeypatch.setattr(agent_factory_module, "OpenAICredential", StubCredential)
    monkeypatch.setattr(agent_factory_module, "OpenAIChatModel", StubOpenAIChatModel)
    monkeypatch.setattr(agent_factory_module, "Toolkit", StubToolkit)
    monkeypatch.setattr(agent_factory_module, "Agent", StubAgent)
    monkeypatch.setattr(agent_factory_module, "SeraphKnowledgeBase", lambda **kwargs: object())

    factory = agent_factory_module.AgentFactory(
        chat_model_name="gpt-5.4",
        api_key="test-key",
        base_url="   ",
        retrieval_service=object(),
        spaces_client=object(),
    )

    factory.create(user_id="alice", session_id="session-1")

    assert recorded["api_key"] == "test-key"
    assert recorded["base_url"] == "https://api.openai.com/v1"


def test_agent_factory_builds_knowledge_tool_and_file_tools(monkeypatch: pytest.MonkeyPatch) -> None:
    importlib.import_module("chat.tools")
    agent_factory_module = importlib.import_module("chat.agent_factory")
    tools_module = importlib.import_module("chat.tools")
    recorded: dict[str, Any] = {}

    class StubOpenAIChatModel:
        def __init__(self, **kwargs: object) -> None:
            recorded["model_kwargs"] = kwargs

    class StubToolkit:
        def __init__(self, tools: list[object] | None = None) -> None:
            self.tools = tools or []

    class StubAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded["agent_kwargs"] = kwargs

    monkeypatch.setattr(agent_factory_module, "OpenAIChatModel", StubOpenAIChatModel)
    monkeypatch.setattr(agent_factory_module, "Toolkit", StubToolkit)
    monkeypatch.setattr(agent_factory_module, "Agent", StubAgent)

    def file_access_factory(user_id: str):
        class DummyFileAccess:
            pass

        return DummyFileAccess()

    factory = agent_factory_module.AgentFactory(
        chat_model_name="gpt-test",
        api_key="test-key",
        base_url=None,
        retrieval_service=object(),
        spaces_client=object(),
        file_access_service_factory=file_access_factory,
    )

    factory.create(user_id="alice", session_id="session-1")

    toolkit = recorded["agent_kwargs"]["toolkit"]
    tool_types = {type(tool) for tool in toolkit.tools}
    assert len(toolkit.tools) == 5
    assert tools_module.SearchKnowledgeBaseTool in tool_types
    assert tools_module.SearchFilesTool in tool_types
    assert tools_module.ListDirectoryTool in tool_types
    assert tools_module.StatFileTool in tool_types
    assert tools_module.ReadFileExcerptTool in tool_types
