from __future__ import annotations

from typing import Any

from agentscope.agent import ReActAgent
from agentscope.formatter import OpenAIChatFormatter
from agentscope.memory import AsyncSQLAlchemyMemory
from agentscope.message import TextBlock
from agentscope.model import OpenAIChatModel
from agentscope.tool import Toolkit, ToolResponse

from chat.prompts import DOCUMENT_CHAT_PROMPT
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
        engine: Any,
        chat_model_name: str,
        api_key: str | None,
        base_url: str | None,
        embedding_model: Any,
        retrieval_service: Any,
        spaces_client: Any,
        search_client: Any = None,
        file_access_service_factory: Any = None,
    ) -> None:
        self._engine = engine
        self._chat_model_name = chat_model_name
        self._api_key = api_key
        self._base_url = base_url
        self._embedding_model = embedding_model
        self._retrieval_service = retrieval_service
        self._spaces_client = spaces_client
        self._search_client = search_client
        self._file_access_service_factory = file_access_service_factory

    def create(self, user_id: str, session_id: str) -> ReActAgent:
        client_kwargs: dict[str, Any] = {
            "base_url": _normalize_openai_base_url(self._base_url) or DEFAULT_OPENAI_BASE_URL
        }
        toolkit = Toolkit()
        if self._file_access_service_factory is not None:
            file_access = self._file_access_service_factory(user_id)

            def _tool_response(payload: Any) -> ToolResponse:
                return ToolResponse(
                    content=[TextBlock(type="text", text=str(payload))],
                    metadata={"result": payload},
                )

            async def search_files(query: str) -> ToolResponse:
                return _tool_response(await file_access.search_files(user_id=user_id, query=query))

            async def list_directory(provider_id: str, path: str) -> ToolResponse:
                return _tool_response(await file_access.list_directory(user_id=user_id, provider_id=provider_id, path=path))

            async def stat_file(provider_id: str, path: str) -> ToolResponse:
                return _tool_response(await file_access.stat_file(user_id=user_id, provider_id=provider_id, path=path))

            async def read_file_excerpt(
                provider_id: str,
                path: str,
                start_line: int = 1,
                max_lines: int = 80,
                max_chars: int = 12000,
            ) -> ToolResponse:
                return _tool_response(
                    await file_access.read_file_excerpt(
                        user_id=user_id,
                        provider_id=provider_id,
                        path=path,
                        start_line=start_line,
                        max_lines=max_lines,
                        max_chars=max_chars,
                    )
                )

            toolkit.register_tool_function(
                search_files,
                func_name="search_files",
                func_description="Search accessible files by name",
                async_execution=False,
            )
            toolkit.register_tool_function(
                list_directory,
                func_name="list_directory",
                func_description="List accessible directory entries",
                async_execution=False,
            )
            toolkit.register_tool_function(
                stat_file,
                func_name="stat_file",
                func_description="Inspect accessible file metadata",
                async_execution=False,
            )
            toolkit.register_tool_function(
                read_file_excerpt,
                func_name="read_file_excerpt",
                func_description="Read bounded lines from an accessible text file",
                async_execution=False,
            )
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
            toolkit=toolkit,
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
