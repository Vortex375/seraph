from __future__ import annotations

from typing import Any

from agentscope.agent import ReActAgent
from agentscope.formatter import OpenAIChatFormatter
from agentscope.memory import AsyncSQLAlchemyMemory
from agentscope.model import OpenAIChatModel
from agentscope.tool import Toolkit

from chat.prompts import DOCUMENT_CHAT_PROMPT
from knowledge.seraph_knowledge import SeraphKnowledgeBase


class AgentFactory:
    def __init__(
        self,
        engine: Any,
        chat_model_name: str,
        api_key: str | None,
        base_url: str | None,
        embedding_model: Any,
        retrieval_service: Any,
        spaces_client: Any,
    ) -> None:
        self._engine = engine
        self._chat_model_name = chat_model_name
        self._api_key = api_key
        self._base_url = base_url
        self._embedding_model = embedding_model
        self._retrieval_service = retrieval_service
        self._spaces_client = spaces_client

    def create(self, user_id: str, session_id: str) -> ReActAgent:
        client_kwargs: dict[str, Any] | None = {"base_url": self._base_url} if self._base_url else None
        return ReActAgent(
            name="seraph-documents",
            sys_prompt=DOCUMENT_CHAT_PROMPT,
            model=OpenAIChatModel(
                model_name=self._chat_model_name,
                api_key=self._api_key,
                client_kwargs=client_kwargs,
                stream=True,
            ),
            formatter=OpenAIChatFormatter(),
            toolkit=Toolkit(),
            memory=AsyncSQLAlchemyMemory(self._engine, session_id=session_id, user_id=user_id),
            knowledge=SeraphKnowledgeBase(
                embedding_store=None,
                embedding_model=self._embedding_model,
                retrieval_service=self._retrieval_service,
                spaces_client=self._spaces_client,
                user_id=user_id,
            ),
            enable_rewrite_query=False,
        )
