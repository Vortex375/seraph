from __future__ import annotations

from typing import Any

from agentscope.agent import ReActAgent
from agentscope.formatter import DeepSeekChatFormatter
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


def _extract_tool_citations(payload: Any) -> list[dict[str, str]]:
    if isinstance(payload, list):
        return [citation for item in payload for citation in _extract_tool_citations(item)]

    if not isinstance(payload, dict):
        return []

    reference = payload.get("reference")
    if isinstance(reference, dict):
        return _extract_tool_citations(reference)

    provider_id = payload.get("provider_id")
    path = payload.get("path")
    if isinstance(provider_id, str) and provider_id and isinstance(path, str) and path:
        label = payload.get("label")
        return [{"provider_id": provider_id, "path": path, "label": label if isinstance(label, str) and label else path}]

    return []


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
        agent: ReActAgent | None = None
        if self._file_access_service_factory is not None:
            file_access = self._file_access_service_factory(user_id)

            def _remember_tool_citations(payload: Any) -> None:
                if agent is None:
                    return
                citations = getattr(agent, "_seraph_tool_citations", None)
                if not isinstance(citations, list):
                    return

                seen = {
                    (provider_id, path)
                    for provider_id, path in (
                        (citation.get("provider_id"), citation.get("path"))
                        for citation in citations
                        if isinstance(citation, dict)
                    )
                    if isinstance(provider_id, str) and provider_id and isinstance(path, str) and path
                }
                for citation in _extract_tool_citations(payload):
                    key = (citation["provider_id"], citation["path"])
                    if key in seen:
                        continue
                    citations.append(citation)
                    seen.add(key)

            def _tool_response(payload: Any) -> ToolResponse:
                _remember_tool_citations(payload)
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
        agent = ReActAgent(
            name="seraph-documents",
            sys_prompt=DOCUMENT_CHAT_PROMPT,
            model=OpenAIChatModel(
                model_name=self._chat_model_name,
                api_key=self._api_key,
                client_kwargs=client_kwargs,
                stream=True,
            ),
            formatter=DeepSeekChatFormatter(),
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
        return agent
