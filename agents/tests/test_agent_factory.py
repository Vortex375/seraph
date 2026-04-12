import importlib
import sys
from pathlib import Path

import pytest

sys.path.append(str(Path(__file__).resolve().parents[1]))


def test_agent_factory_uses_default_openai_base_url_when_blank(monkeypatch: pytest.MonkeyPatch) -> None:
    agent_factory_module = importlib.import_module("chat.agent_factory")
    recorded: dict[str, object] = {}

    class StubOpenAIChatModel:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    class StubReActAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded["agent_kwargs"] = kwargs

    monkeypatch.setattr(agent_factory_module, "OpenAIChatModel", StubOpenAIChatModel)
    monkeypatch.setattr(agent_factory_module, "ReActAgent", StubReActAgent)
    monkeypatch.setattr(agent_factory_module, "AsyncSQLAlchemyMemory", lambda *args, **kwargs: object())
    monkeypatch.setattr(agent_factory_module, "OpenAIChatFormatter", lambda: object())
    monkeypatch.setattr(agent_factory_module, "Toolkit", lambda: object())
    monkeypatch.setattr(agent_factory_module, "SeraphKnowledgeBase", lambda **kwargs: object())

    factory = agent_factory_module.AgentFactory(
        engine=object(),
        chat_model_name="gpt-5.4",
        api_key="test-key",
        base_url=None,
        embedding_model=object(),
        retrieval_service=object(),
        spaces_client=object(),
    )

    factory.create(user_id="alice", session_id="session-1")

    assert recorded["api_key"] == "test-key"
    assert recorded["client_kwargs"] == {"base_url": "https://api.openai.com/v1"}


def test_agent_factory_uses_default_openai_base_url_when_whitespace_only(monkeypatch: pytest.MonkeyPatch) -> None:
    agent_factory_module = importlib.import_module("chat.agent_factory")
    recorded: dict[str, object] = {}

    class StubOpenAIChatModel:
        def __init__(self, **kwargs: object) -> None:
            recorded.update(kwargs)

    class StubReActAgent:
        def __init__(self, **kwargs: object) -> None:
            recorded["agent_kwargs"] = kwargs

    monkeypatch.setattr(agent_factory_module, "OpenAIChatModel", StubOpenAIChatModel)
    monkeypatch.setattr(agent_factory_module, "ReActAgent", StubReActAgent)
    monkeypatch.setattr(agent_factory_module, "AsyncSQLAlchemyMemory", lambda *args, **kwargs: object())
    monkeypatch.setattr(agent_factory_module, "OpenAIChatFormatter", lambda: object())
    monkeypatch.setattr(agent_factory_module, "Toolkit", lambda: object())
    monkeypatch.setattr(agent_factory_module, "SeraphKnowledgeBase", lambda **kwargs: object())

    factory = agent_factory_module.AgentFactory(
        engine=object(),
        chat_model_name="gpt-5.4",
        api_key="test-key",
        base_url="   ",
        embedding_model=object(),
        retrieval_service=object(),
        spaces_client=object(),
    )

    factory.create(user_id="alice", session_id="session-1")

    assert recorded["api_key"] == "test-key"
    assert recorded["client_kwargs"] == {"base_url": "https://api.openai.com/v1"}
