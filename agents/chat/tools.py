from __future__ import annotations

import json
from typing import Any

from agentscope.message import TextBlock
from agentscope.permission import PermissionBehavior, PermissionContext, PermissionDecision
from agentscope.tool import ToolBase
from agentscope.tool._response import ToolChunk

from chat.file_access import AgentFileAccessService
from knowledge.seraph_knowledge import SeraphKnowledgeBase, SeraphKnowledgeDocument


def _citation_from_hit(hit: dict[str, Any]) -> dict[str, str]:
    provider_id = hit.get("provider_id") if isinstance(hit, dict) else getattr(hit, "provider_id", None)
    path = hit.get("path") if isinstance(hit, dict) else getattr(hit, "path", None)
    label = hit.get("label") if isinstance(hit, dict) else getattr(hit, "label", None)
    if not isinstance(provider_id, str) or not provider_id:
        return {}
    if not isinstance(path, str) or not path:
        return {}
    return {"provider_id": provider_id, "path": path, "label": label if isinstance(label, str) and label else path}


def _citations_from_hits(hits: list[dict[str, Any]]) -> list[dict[str, str]]:
    seen: set[tuple[str, str]] = set()
    citations: list[dict[str, str]] = []
    for hit in hits:
        citation = _citation_from_hit(hit)
        if not citation:
            continue
        key = (citation["provider_id"], citation["path"])
        if key in seen:
            continue
        seen.add(key)
        citations.append(citation)
    return citations


class SearchFilesTool(ToolBase):
    name = "search_files"
    description = "Search accessible files by name or content fragment. Returns file paths the assistant can read."
    input_schema = {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "Search query for matching files.",
            },
        },
        "required": ["query"],
    }
    is_concurrency_safe = True
    is_read_only = True

    def __init__(self, file_access: AgentFileAccessService, user_id: str) -> None:
        self._file_access = file_access
        self._user_id = user_id
        self._citations: list[dict[str, str]] = []

    async def check_permissions(
        self, tool_input: dict[str, Any], context: PermissionContext
    ) -> PermissionDecision:
        del tool_input, context
        return PermissionDecision(
            behavior=PermissionBehavior.ALLOW,
            message="File search is read-only.",
        )

    async def __call__(self, query: str) -> ToolChunk:
        hits = await self._file_access.search_files(user_id=self._user_id, query=query)
        self._citations = _citations_from_hits(hits)
        return ToolChunk(
            content=[TextBlock(text=json.dumps(hits, ensure_ascii=False))],
            metadata={"citations": self._citations},
        )


class ListDirectoryTool(ToolBase):
    name = "list_directory"
    description = "List entries in an accessible directory."
    input_schema = {
        "type": "object",
        "properties": {
            "provider_id": {
                "type": "string",
                "description": "Space/provider identifier.",
            },
            "path": {
                "type": "string",
                "description": "Directory path to list.",
            },
        },
        "required": ["provider_id", "path"],
    }
    is_concurrency_safe = True
    is_read_only = True

    def __init__(self, file_access: AgentFileAccessService, user_id: str) -> None:
        self._file_access = file_access
        self._user_id = user_id
        self._citations: list[dict[str, str]] = []

    async def check_permissions(
        self, tool_input: dict[str, Any], context: PermissionContext
    ) -> PermissionDecision:
        del tool_input, context
        return PermissionDecision(
            behavior=PermissionBehavior.ALLOW,
            message="Directory listing is read-only.",
        )

    async def __call__(self, provider_id: str, path: str) -> ToolChunk:
        entries = await self._file_access.list_directory(
            user_id=self._user_id, provider_id=provider_id, path=path
        )
        self._citations = []
        return ToolChunk(
            content=[TextBlock(text=json.dumps(entries, ensure_ascii=False))],
            metadata={"citations": []},
        )


class StatFileTool(ToolBase):
    name = "stat_file"
    description = "Inspect accessible file metadata (size, modification time, type)."
    input_schema = {
        "type": "object",
        "properties": {
            "provider_id": {
                "type": "string",
                "description": "Space/provider identifier.",
            },
            "path": {
                "type": "string",
                "description": "File or directory path to inspect.",
            },
        },
        "required": ["provider_id", "path"],
    }
    is_concurrency_safe = True
    is_read_only = True

    def __init__(self, file_access: AgentFileAccessService, user_id: str) -> None:
        self._file_access = file_access
        self._user_id = user_id
        self._citations: list[dict[str, str]] = []

    async def check_permissions(
        self, tool_input: dict[str, Any], context: PermissionContext
    ) -> PermissionDecision:
        del tool_input, context
        return PermissionDecision(
            behavior=PermissionBehavior.ALLOW,
            message="File metadata lookup is read-only.",
        )

    async def __call__(self, provider_id: str, path: str) -> ToolChunk:
        info = await self._file_access.stat_file(
            user_id=self._user_id, provider_id=provider_id, path=path
        )
        self._citations = _citations_from_hits([info])
        return ToolChunk(
            content=[TextBlock(text=json.dumps(info, ensure_ascii=False))],
            metadata={"citations": self._citations},
        )


class ReadFileExcerptTool(ToolBase):
    name = "read_file_excerpt"
    description = "Read a bounded text excerpt from an accessible file."
    input_schema = {
        "type": "object",
        "properties": {
            "provider_id": {
                "type": "string",
                "description": "Space/provider identifier.",
            },
            "path": {
                "type": "string",
                "description": "File path to read.",
            },
            "start_line": {
                "type": "integer",
                "description": "First line to include (1-based).",
                "default": 1,
            },
            "max_lines": {
                "type": "integer",
                "description": "Maximum number of lines to read.",
                "default": 80,
            },
            "max_chars": {
                "type": "integer",
                "description": "Maximum characters to return.",
                "default": 12000,
            },
        },
        "required": ["provider_id", "path"],
    }
    is_concurrency_safe = True
    is_read_only = True

    def __init__(self, file_access: AgentFileAccessService, user_id: str) -> None:
        self._file_access = file_access
        self._user_id = user_id
        self._citations: list[dict[str, str]] = []

    async def check_permissions(
        self, tool_input: dict[str, Any], context: PermissionContext
    ) -> PermissionDecision:
        del tool_input, context
        return PermissionDecision(
            behavior=PermissionBehavior.ALLOW,
            message="Reading file excerpts is read-only.",
        )

    async def __call__(
        self,
        provider_id: str,
        path: str,
        start_line: int = 1,
        max_lines: int = 80,
        max_chars: int = 12000,
    ) -> ToolChunk:
        excerpt = await self._file_access.read_file_excerpt(
            user_id=self._user_id,
            provider_id=provider_id,
            path=path,
            start_line=start_line,
            max_lines=max_lines,
            max_chars=max_chars,
        )
        self._citations = _citations_from_hits([excerpt.get("reference", {})])
        return ToolChunk(
            content=[TextBlock(text=json.dumps(excerpt, ensure_ascii=False))],
            metadata={"citations": self._citations},
        )


class SearchKnowledgeBaseTool(ToolBase):
    name = "search_knowledge_base"
    description = (
        "Search the user's indexed documents for semantically relevant chunks. "
        "Use this when the user's question depends on document content. "
        "Do not use this for greetings or off-document small talk."
    )
    input_schema = {
        "type": "object",
        "properties": {
            "query": {
                "type": "string",
                "description": "Search query in natural language.",
            },
            "limit": {
                "type": "integer",
                "description": "Maximum number of chunks to retrieve.",
                "default": 5,
            },
            "min_score": {
                "type": "number",
                "description": "Minimum relevance score (0..1). Lower values return more results.",
                "default": 0.0,
            },
        },
        "required": ["query"],
    }
    is_concurrency_safe = True
    is_read_only = True

    def __init__(self, knowledge: SeraphKnowledgeBase) -> None:
        self._knowledge = knowledge
        self._citations: list[dict[str, str]] = []

    async def check_permissions(
        self, tool_input: dict[str, Any], context: PermissionContext
    ) -> PermissionDecision:
        del tool_input, context
        return PermissionDecision(
            behavior=PermissionBehavior.ALLOW,
            message="Knowledge base search is read-only.",
        )

    async def __call__(
        self, query: str, limit: int = 5, min_score: float = 0.0
    ) -> ToolChunk:
        documents = await self._knowledge.search(query=query, limit=limit, min_score=min_score)
        hits = [_document_to_hit(doc) for doc in documents]
        self._citations = _citations_from_hits(hits)
        return ToolChunk(
            content=[TextBlock(text=json.dumps(hits, ensure_ascii=False))],
            metadata={"citations": self._citations},
        )


def _document_to_hit(document: SeraphKnowledgeDocument) -> dict[str, Any]:
    return {
        "provider_id": document.provenance.provider_id,
        "path": document.provenance.path,
        "label": document.provenance.path,
        "chunk_index": document.chunk_index,
        "total_chunks": document.total_chunks,
        "content": document.content,
        "score": document.score,
    }
