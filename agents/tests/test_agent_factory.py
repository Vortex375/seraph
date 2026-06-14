import importlib
import json
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
    assert len(toolkit.tools) == 6
    assert tools_module.SearchKnowledgeBaseTool in tool_types
    assert tools_module.GetCurrentDateTimeTool in tool_types
    assert tools_module.SearchFilesTool in tool_types
    assert tools_module.ListDirectoryTool in tool_types
    assert tools_module.StatFileTool in tool_types
    assert tools_module.ReadFileExcerptTool in tool_types


def test_agent_factory_injects_current_datetime_for_new_session(monkeypatch: pytest.MonkeyPatch) -> None:
    agent_factory_module = importlib.import_module("chat.agent_factory")
    tools_module = importlib.import_module("chat.tools")
    recorded: dict[str, Any] = {}

    monkeypatch.setattr(
        tools_module,
        "format_current_datetime",
        lambda: "2026-06-14T12:34:56+00:00",
    )

    class StubToolkit:
        def __init__(self, tools: list[object] | None = None) -> None:
            self.tools = tools or []

    class StubAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded["agent_kwargs"] = kwargs

    monkeypatch.setattr(agent_factory_module, "OpenAIChatModel", lambda **kwargs: object())
    monkeypatch.setattr(agent_factory_module, "Toolkit", StubToolkit)
    monkeypatch.setattr(agent_factory_module, "Agent", StubAgent)
    monkeypatch.setattr(agent_factory_module, "SeraphKnowledgeBase", lambda **kwargs: object())

    factory = agent_factory_module.AgentFactory(
        chat_model_name="gpt-test",
        api_key="test-key",
        base_url=None,
        retrieval_service=object(),
        spaces_client=object(),
    )

    factory.create(user_id="alice", session_id="session-1", is_new_session=True)

    system_prompt = recorded["agent_kwargs"]["system_prompt"]
    assert "Current date/time: 2026-06-14T12:34:56+00:00" in system_prompt
    assert "prefer information from more recent documents" in system_prompt


def test_agent_factory_reuses_provided_system_prompt(monkeypatch: pytest.MonkeyPatch) -> None:
    agent_factory_module = importlib.import_module("chat.agent_factory")
    recorded: dict[str, Any] = {}

    class StubToolkit:
        def __init__(self, tools: list[object] | None = None) -> None:
            self.tools = tools or []

    class StubAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded["agent_kwargs"] = kwargs

    monkeypatch.setattr(agent_factory_module, "OpenAIChatModel", lambda **kwargs: object())
    monkeypatch.setattr(agent_factory_module, "Toolkit", StubToolkit)
    monkeypatch.setattr(agent_factory_module, "Agent", StubAgent)
    monkeypatch.setattr(agent_factory_module, "SeraphKnowledgeBase", lambda **kwargs: object())

    factory = agent_factory_module.AgentFactory(
        chat_model_name="gpt-test",
        api_key="test-key",
        base_url=None,
        retrieval_service=object(),
        spaces_client=object(),
    )

    provided = "Custom system prompt"
    factory.create(user_id="alice", session_id="session-1", system_prompt=provided)

    assert recorded["agent_kwargs"]["system_prompt"] == provided


def test_agent_factory_omits_datetime_when_not_new_session(monkeypatch: pytest.MonkeyPatch) -> None:
    agent_factory_module = importlib.import_module("chat.agent_factory")
    prompts_module = importlib.import_module("chat.prompts")
    recorded: dict[str, Any] = {}

    class StubToolkit:
        def __init__(self, tools: list[object] | None = None) -> None:
            self.tools = tools or []

    class StubAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded["agent_kwargs"] = kwargs

    monkeypatch.setattr(agent_factory_module, "OpenAIChatModel", lambda **kwargs: object())
    monkeypatch.setattr(agent_factory_module, "Toolkit", StubToolkit)
    monkeypatch.setattr(agent_factory_module, "Agent", StubAgent)
    monkeypatch.setattr(agent_factory_module, "SeraphKnowledgeBase", lambda **kwargs: object())

    factory = agent_factory_module.AgentFactory(
        chat_model_name="gpt-test",
        api_key="test-key",
        base_url=None,
        retrieval_service=object(),
        spaces_client=object(),
    )

    factory.create(user_id="alice", session_id="session-1", is_new_session=False)

    system_prompt = recorded["agent_kwargs"]["system_prompt"]
    assert "Current date/time:" not in system_prompt
    assert prompts_module.render_system_prompt() == system_prompt


@pytest.mark.asyncio
async def test_get_current_datetime_tool_returns_iso_datetime(monkeypatch: pytest.MonkeyPatch) -> None:
    tools_module = importlib.import_module("chat.tools")
    monkeypatch.setattr(tools_module, "format_current_datetime", lambda: "2026-06-14T12:00:00+00:00")
    tool = tools_module.GetCurrentDateTimeTool()

    decision = await tool.check_permissions({}, object())  # type: ignore[arg-type]
    assert decision.behavior.value == "allow"

    chunk = await tool()
    assert chunk.metadata == {"citations": []}
    payload = json.loads(chunk.content[0].text)
    assert payload == {"current_datetime": "2026-06-14T12:00:00+00:00"}
