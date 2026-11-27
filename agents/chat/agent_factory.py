from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from pydantic_ai import Agent, ModelMessage
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider

from chat.agent_state_store import AgentStateStore
from chat.prompts import render_system_prompt
from chat.tools import BASE_TOOLS, FILE_TOOLS, ChatDeps, format_current_datetime
from knowledge.seraph_knowledge import SeraphKnowledgeBase


DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1"


def _normalize_openai_base_url(base_url: str | None) -> str | None:
    if base_url is None:
        return None
    normalized = base_url.strip()
    return normalized or None


@dataclass
class ChatAgent:
    """One chat turn: the agent, its tool deps, and the session's message history (updated after the run)."""

    agent: Agent[ChatDeps, str]
    deps: ChatDeps
    state: list[ModelMessage] = field(default_factory=list)


class AgentFactory:
    def __init__(
        self,
        chat_model_name: str,
        api_key: str | None,
        base_url: str | None,
        retrieval_service: Any,
        spaces_client: Any,
        file_access_service_factory: Any = None,
        state_store: AgentStateStore | None = None,
    ) -> None:
        self._chat_model_name = chat_model_name
        self._api_key = api_key
        self._base_url = _normalize_openai_base_url(base_url)
        self._retrieval_service = retrieval_service
        self._spaces_client = spaces_client
        self._file_access_service_factory = file_access_service_factory
        self._state_store = state_store or AgentStateStore()

    def create(
        self,
        user_id: str,
        state: list[ModelMessage] | None = None,
        *,
        is_new_session: bool = False,
        system_prompt: str | None = None,
    ) -> ChatAgent:
        model = OpenAIChatModel(
            self._chat_model_name,
            provider=OpenAIProvider(base_url=self._base_url or DEFAULT_OPENAI_BASE_URL, api_key=self._api_key or None),
        )

        file_access = None
        if self._file_access_service_factory is not None:
            file_access = self._file_access_service_factory(user_id)

        if system_prompt is None:
            system_prompt = render_system_prompt(current_datetime=format_current_datetime() if is_new_session else None)

        knowledge = SeraphKnowledgeBase(
            retrieval_service=self._retrieval_service,
            spaces_client=self._spaces_client,
            user_id=user_id,
        )
        agent = Agent(
            model,
            name="seraph-documents",
            instructions=system_prompt,
            deps_type=ChatDeps,
            tools=[*BASE_TOOLS, *(FILE_TOOLS if file_access is not None else [])],
        )
        return ChatAgent(
            agent=agent,
            deps=ChatDeps(user_id=user_id, knowledge=knowledge, file_access=file_access),
            state=state or [],
        )

    async def load_state(self, user_id: str, session_id: str) -> list[ModelMessage] | None:
        return await self._state_store.load(user_id=user_id, session_id=session_id)

    async def save_state(self, user_id: str, session_id: str, state: list[ModelMessage]) -> None:
        await self._state_store.save(user_id=user_id, session_id=session_id, state=state)
