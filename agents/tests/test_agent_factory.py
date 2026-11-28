from typing import Any

import pytest
from pydantic_ai.messages import ModelMessage, ModelResponse, TextPart
from pydantic_ai.models.function import AgentInfo, FunctionModel

from chat import tools as tools_module
from chat.agent_factory import AgentFactory, build_chat_model
from tests.support import StubRetrieval, StubSpaces


async def _agent_info(factory: AgentFactory, instructions: str = "Be helpful.") -> AgentInfo:
    """Run one turn and return what the model was offered."""
    captured: list[AgentInfo] = []

    def respond(messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        del messages
        captured.append(info)
        return ModelResponse(parts=[TextPart("ok")])

    chat_agent = factory.create("alice", [], instructions)
    with chat_agent.agent.override(model=FunctionModel(respond)):
        await chat_agent.agent.run("hi", deps=chat_agent.deps)
    return captured[0]


def _factory(file_access: Any = None) -> AgentFactory:
    return AgentFactory(
        model=FunctionModel(lambda messages, info: ModelResponse(parts=[TextPart("ok")])),
        retrieval_service=StubRetrieval(),
        spaces_client=StubSpaces(),
        file_access=file_access,
    )


@pytest.mark.parametrize("base_url", [None, "", "   "])
def test_build_chat_model_defaults_blank_base_url_to_openai(base_url: str | None) -> None:
    model = build_chat_model("gpt-5.4", "test-key", base_url)

    assert model.model_name == "gpt-5.4"
    assert str(model.client.base_url) == "https://api.openai.com/v1/"
    assert model.client.api_key == "test-key"


def test_build_chat_model_uses_custom_base_url() -> None:
    model = build_chat_model("google/gemma", "test-key", " https://openrouter.ai/api/v1 ")

    assert str(model.client.base_url) == "https://openrouter.ai/api/v1/"


@pytest.mark.asyncio
async def test_agent_factory_registers_file_tools_only_with_file_access() -> None:
    without_files = await _agent_info(_factory())
    with_files = await _agent_info(_factory(file_access=object()))

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
async def test_agent_factory_passes_instructions_to_the_model() -> None:
    info = await _agent_info(_factory(), instructions="Custom system prompt")

    assert info.instructions == "Custom system prompt"


def test_get_current_datetime_tool_returns_iso_datetime(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(tools_module, "format_current_datetime", lambda: "2026-06-14T12:00:00+00:00")

    assert tools_module.get_current_datetime() == {"current_datetime": "2026-06-14T12:00:00+00:00"}
