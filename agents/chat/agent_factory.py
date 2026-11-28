from __future__ import annotations

from collections.abc import AsyncIterator
from dataclasses import dataclass, field
from typing import Any

from pydantic import ValidationError
from pydantic_ai import (
    Agent,
    AgentRunResultEvent,
    ModelMessage,
    ModelMessagesTypeAdapter,
    PartDeltaEvent,
    PartStartEvent,
    TextPart,
    TextPartDelta,
)
from pydantic_ai.models import Model
from pydantic_ai.models.openai import OpenAIChatModel
from pydantic_ai.providers.openai import OpenAIProvider

from chat.file_access import AgentFileAccessService
from chat.prompts import DOCUMENT_CHAT_PROMPT, TITLE_PROMPT, current_datetime
from chat.tools import BASE_TOOLS, FILE_TOOLS, ChatDeps
from knowledge.seraph_knowledge import Retriever, ScopeProvider, SeraphKnowledgeBase


DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1"


def build_chat_model(model_name: str, api_key: str | None, base_url: str | None) -> OpenAIChatModel:
    """Chat model on any OpenAI-compatible endpoint; a blank base URL means OpenAI itself."""
    provider = OpenAIProvider(base_url=(base_url or "").strip() or DEFAULT_OPENAI_BASE_URL, api_key=api_key or None)
    return OpenAIChatModel(model_name, provider=provider)


def load_history(raw_state: Any) -> list[ModelMessage] | None:
    """Parse a persisted message history; unreadable state (e.g. pre-Pydantic-AI) yields ``None``."""
    if not raw_state:
        return None
    try:
        return ModelMessagesTypeAdapter.validate_python(raw_state)
    except ValidationError:
        return None


def dump_history(history: list[ModelMessage]) -> Any:
    return ModelMessagesTypeAdapter.dump_python(history, mode="json")


@dataclass
class ChatAgent:
    """One chat turn: the agent, its tool deps, and the session's message history (extended by ``stream``)."""

    agent: Agent[ChatDeps, str]
    deps: ChatDeps
    history: list[ModelMessage] = field(default_factory=list)

    async def stream(self, user_input: str, run_id: str) -> AsyncIterator[str]:
        """Run the turn and yield the reply's text deltas; ``run_id`` tags every message the run adds."""
        async with self.agent.run_stream_events(
            user_input, message_history=self.history, deps=self.deps, run_id=run_id
        ) as events:
            async for event in events:
                if isinstance(event, PartStartEvent) and isinstance(event.part, TextPart) and event.part.content:
                    yield event.part.content
                elif isinstance(event, PartDeltaEvent) and isinstance(event.delta, TextPartDelta):
                    yield event.delta.content_delta
                elif isinstance(event, AgentRunResultEvent):
                    self.history = event.result.all_messages()


class AgentFactory:
    def __init__(
        self,
        model: Model,
        retrieval_service: Retriever,
        spaces_client: ScopeProvider,
        file_access: AgentFileAccessService | None = None,
    ) -> None:
        self._model = model
        self._retrieval_service = retrieval_service
        self._spaces_client = spaces_client
        self._file_access = file_access
        self._title_agent = Agent(model, name="seraph-titles", instructions=TITLE_PROMPT)

    async def title(self, first_message: str) -> str:
        """A short title for a chat, from its first user message."""
        return (await self._title_agent.run(first_message)).output

    def create(self, user_id: str, history: list[ModelMessage]) -> ChatAgent:
        agent = Agent(
            self._model,
            name="seraph-documents",
            instructions=DOCUMENT_CHAT_PROMPT,
            deps_type=ChatDeps,
            tools=[*BASE_TOOLS, *(FILE_TOOLS if self._file_access is not None else [])],
        )
        # Appended to history when it changes, so the time stays current without invalidating the cached prefix.
        agent.instructions(name="current_datetime", on_change="append")(current_datetime)
        knowledge = SeraphKnowledgeBase(self._retrieval_service, self._spaces_client, user_id)
        deps = ChatDeps(user_id=user_id, knowledge=knowledge, file_access=self._file_access)
        return ChatAgent(agent=agent, deps=deps, history=history)
