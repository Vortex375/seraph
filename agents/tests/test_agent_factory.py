import importlib
import sys
from pathlib import Path
from typing import Any

import pytest
from pydantic_ai.messages import ModelMessage
from pydantic_ai.models.function import AgentInfo, FunctionModel

sys.path.append(str(Path(__file__).resolve().parents[1]))


def _factory(**kwargs: Any) -> Any:
    agent_factory_module = importlib.import_module("chat.agent_factory")
    defaults: dict[str, Any] = {
        "chat_model_name": "gpt-test",
        "api_key": "test-key",
        "base_url": None,
        "retrieval_service": object(),
        "spaces_client": object(),
    }
    return agent_factory_module.AgentFactory(**(defaults | kwargs))


async def _agent_info(chat_agent: Any) -> AgentInfo:
    """Run the agent once against a FunctionModel and return what the model was offered."""
    captured: list[AgentInfo] = []

    def respond(messages: list[ModelMessage], info: AgentInfo) -> Any:
        from pydantic_ai.messages import ModelResponse, TextPart

        captured.append(info)
        return ModelResponse(parts=[TextPart("ok")])

    with chat_agent.agent.override(model=FunctionModel(respond)):
        await chat_agent.agent.run("hi", deps=chat_agent.deps)
    return captured[0]


@pytest.mark.parametrize("base_url", [None, "   "])
def test_agent_factory_uses_default_openai_base_url_when_blank(base_url: str | None) -> None:
    chat_agent = _factory(chat_model_name="gpt-5.4", base_url=base_url).create(user_id="alice")

    model = chat_agent.agent.model
    assert model.model_name == "gpt-5.4"
    assert str(model.client.base_url) == "https://api.openai.com/v1/"
    assert model.client.api_key == "test-key"


@pytest.mark.asyncio
async def test_agent_factory_registers_file_tools_only_with_file_access() -> None:
    without_files = await _agent_info(_factory().create(user_id="alice"))
    with_files = await _agent_info(_factory(file_access_service_factory=lambda user_id: object()).create("alice"))

    assert {tool.name for tool in without_files.function_tools} == {"search_knowledge_base", "get_current_datetime"}
    assert {tool.name for tool in with_files.function_tools} == {
        "search_knowledge_base",
        "get_current_datetime",
        "search_files",
        "list_directory",
        "stat_file",
        "read_file_excerpt",
    }


@pytest.mark.asyncio
async def test_agent_factory_injects_current_datetime_for_new_session(monkeypatch: pytest.MonkeyPatch) -> None:
    agent_factory_module = importlib.import_module("chat.agent_factory")
    monkeypatch.setattr(agent_factory_module, "format_current_datetime", lambda: "2026-06-14T12:34:56+00:00")

    info = await _agent_info(_factory().create(user_id="alice", is_new_session=True))

    assert "Current date/time: 2026-06-14T12:34:56+00:00" in (info.instructions or "")
    assert "prefer information from more recent documents" in (info.instructions or "")


@pytest.mark.asyncio
async def test_agent_factory_reuses_provided_system_prompt() -> None:
    info = await _agent_info(_factory().create(user_id="alice", system_prompt="Custom system prompt"))

    assert info.instructions == "Custom system prompt"


@pytest.mark.asyncio
async def test_agent_factory_omits_datetime_when_not_new_session() -> None:
    prompts_module = importlib.import_module("chat.prompts")

    info = await _agent_info(_factory().create(user_id="alice", is_new_session=False))

    assert info.instructions == prompts_module.render_system_prompt().strip()


def test_get_current_datetime_tool_returns_iso_datetime(monkeypatch: pytest.MonkeyPatch) -> None:
    tools_module = importlib.import_module("chat.tools")
    monkeypatch.setattr(tools_module, "format_current_datetime", lambda: "2026-06-14T12:00:00+00:00")

    assert tools_module.get_current_datetime() == {"current_datetime": "2026-06-14T12:00:00+00:00"}
