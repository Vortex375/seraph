from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from pydantic_ai import RunContext

from chat.file_access import AgentFileAccessService
from knowledge.seraph_knowledge import SeraphKnowledgeBase, SeraphKnowledgeDocument


def format_current_datetime() -> str:
    """Return the current system date and time as an ISO-8601 string with timezone offset."""
    return datetime.now(timezone.utc).astimezone().isoformat()


@dataclass
class ChatDeps:
    """Per-turn dependencies shared by the chat tools; tools append the files they surface to ``citations``."""

    user_id: str
    knowledge: SeraphKnowledgeBase
    file_access: AgentFileAccessService | None = None
    citations: list[dict[str, str]] = field(default_factory=list)

    def files(self) -> AgentFileAccessService:
        if self.file_access is None:
            raise RuntimeError("file tools are not configured")
        return self.file_access


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


async def search_files(ctx: RunContext[ChatDeps], query: str) -> Any:
    """Search accessible files by name or content fragment. Returns file paths the assistant can read.

    Args:
        query: Search query for matching files.
    """
    hits = await ctx.deps.files().search_files(user_id=ctx.deps.user_id, query=query)
    ctx.deps.citations.extend(_citations_from_hits(hits))
    return hits


async def list_directory(ctx: RunContext[ChatDeps], provider_id: str, path: str) -> Any:
    """List entries in an accessible directory.

    Args:
        provider_id: Space/provider identifier.
        path: Directory path to list.
    """
    return await ctx.deps.files().list_directory(user_id=ctx.deps.user_id, provider_id=provider_id, path=path)


async def stat_file(ctx: RunContext[ChatDeps], provider_id: str, path: str) -> Any:
    """Inspect accessible file metadata (size, modification time, type).

    Args:
        provider_id: Space/provider identifier.
        path: File or directory path to inspect.
    """
    info = await ctx.deps.files().stat_file(user_id=ctx.deps.user_id, provider_id=provider_id, path=path)
    ctx.deps.citations.extend(_citations_from_hits([info]))
    return info


async def read_file_excerpt(
    ctx: RunContext[ChatDeps],
    provider_id: str,
    path: str,
    start_line: int = 1,
    max_lines: int = 80,
    max_chars: int = 12000,
) -> Any:
    """Read a bounded text excerpt from an accessible file.

    Args:
        provider_id: Space/provider identifier.
        path: File path to read.
        start_line: First line to include (1-based).
        max_lines: Maximum number of lines to read.
        max_chars: Maximum characters to return.
    """
    excerpt = await ctx.deps.files().read_file_excerpt(
        user_id=ctx.deps.user_id,
        provider_id=provider_id,
        path=path,
        start_line=start_line,
        max_lines=max_lines,
        max_chars=max_chars,
    )
    ctx.deps.citations.extend(_citations_from_hits([excerpt.get("reference", {})]))
    return excerpt


async def search_knowledge_base(
    ctx: RunContext[ChatDeps], query: str, limit: int = 5, min_score: float = 0.0
) -> list[dict[str, Any]]:
    """Search the user's indexed documents for semantically relevant chunks.

    Use this when the user's question depends on document content.
    Do not use this for greetings or off-document small talk.

    Args:
        query: Search query in natural language.
        limit: Maximum number of chunks to retrieve.
        min_score: Minimum relevance score (0..1). Lower values return more results.
    """
    documents = await ctx.deps.knowledge.search(query=query, limit=limit, min_score=min_score)
    hits = [_document_to_hit(doc) for doc in documents]
    ctx.deps.citations.extend(_citations_from_hits(hits))
    return hits


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


def get_current_datetime() -> dict[str, str]:
    """Return the current date and time. Use this when the user's question depends on the current moment."""
    return {"current_datetime": format_current_datetime()}


BASE_TOOLS: list[Callable[..., Any]] = [search_knowledge_base, get_current_datetime]
FILE_TOOLS: list[Callable[..., Any]] = [search_files, list_directory, stat_file, read_file_excerpt]
