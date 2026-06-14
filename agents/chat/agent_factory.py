from __future__ import annotations

from typing import Any

from agentscope.agent import Agent
from agentscope.credential import OpenAICredential
from agentscope.model import OpenAIChatModel
from agentscope.tool import Toolkit
from agentscope.state import AgentState

from chat.agent_state_store import AgentStateStore
from chat.prompts import DOCUMENT_CHAT_PROMPT
from chat.tools import (
    ListDirectoryTool,
    ReadFileExcerptTool,
    SearchFilesTool,
    SearchKnowledgeBaseTool,
    StatFileTool,
)
from knowledge.seraph_knowledge import SeraphKnowledgeBase


DEFAULT_OPENAI_BASE_URL = "https://api.openai.com/v1"


def _normalize_openai_base_url(base_url: str | None) -> str | None:
    if base_url is None:
        return None
    normalized = base_url.strip()
    return normalized or None


class AgentFactory:
    def __init__(
        self,
        chat_model_name: str,
        api_key: str | None,
        base_url: str | None,
        retrieval_service: Any,
        spaces_client: Any,
        search_client: Any = None,
        file_access_service_factory: Any = None,
        state_store: AgentStateStore | None = None,
    ) -> None:
        self._chat_model_name = chat_model_name
        self._api_key = api_key
        self._base_url = _normalize_openai_base_url(base_url)
        self._retrieval_service = retrieval_service
        self._spaces_client = spaces_client
        self._search_client = search_client
        self._file_access_service_factory = file_access_service_factory
        self._state_store = state_store or AgentStateStore()

    def create(self, user_id: str, session_id: str, state: AgentState | None = None) -> Agent:
        credential = OpenAICredential(
            api_key=self._api_key or "",
            base_url=self._base_url or DEFAULT_OPENAI_BASE_URL,
        )
        model = OpenAIChatModel(
            credential=credential,
            model=self._chat_model_name,
            stream=True,
        )

        file_access = None
        if self._file_access_service_factory is not None:
            file_access = self._file_access_service_factory(user_id)

        tools = self._build_tools(user_id, file_access)
        toolkit = Toolkit(tools=tools)

        if state is None:
            state = AgentState(session_id=session_id)

        return Agent(
            name="seraph-documents",
            system_prompt=DOCUMENT_CHAT_PROMPT,
            model=model,
            toolkit=toolkit,
            state=state,
        )

    async def load_state(self, user_id: str, session_id: str) -> AgentState | None:
        return await self._state_store.load(user_id=user_id, session_id=session_id)

    async def save_state(self, user_id: str, session_id: str, state: AgentState) -> None:
        await self._state_store.save(user_id=user_id, session_id=session_id, state=state)

    def _build_tools(self, user_id: str, file_access: Any) -> list[Any]:
        knowledge = SeraphKnowledgeBase(
            retrieval_service=self._retrieval_service,
            spaces_client=self._spaces_client,
            user_id=user_id,
        )
        tools: list[Any] = [SearchKnowledgeBaseTool(knowledge=knowledge)]

        if file_access is not None:
            tools.extend(
                [
                    SearchFilesTool(file_access=file_access, user_id=user_id),
                    ListDirectoryTool(file_access=file_access, user_id=user_id),
                    StatFileTool(file_access=file_access, user_id=user_id),
                    ReadFileExcerptTool(file_access=file_access, user_id=user_id),
                ]
            )

        return tools
