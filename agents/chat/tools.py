from __future__ import annotations

import functools
import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from typing import Any

from pydantic_ai import RunContext, ToolFailed

from chat.file_access import AgentFileAccessService
from knowledge.seraph_knowledge import SeraphKnowledgeBase, SeraphKnowledgeDocument

logger = logging.getLogger(__name__)


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
    """Find files whose path contains the given words; returns their paths, not their content.

    Use to locate a file by name, or a file that may not be indexed.
    Do not use for questions about what documents say; use search_knowledge_base.

    Args:
        query: Words from the file or folder name.
    """
    hits = await ctx.deps.files().search_files(user_id=ctx.deps.user_id, query=query)
    ctx.deps.citations.extend(_citations_from_hits(hits))
    return hits


async def list_directory(ctx: RunContext[ChatDeps], provider_id: str, path: str) -> Any:
    """List the files and folders in a directory.

    Use when the user asks what a folder contains, or to browse towards a file.
    Do not use to find a file whose location is unknown; use search_files.

    Args:
        provider_id: Space/provider identifier.
        path: Directory path to list.
    """
    return await ctx.deps.files().list_directory(user_id=ctx.deps.user_id, provider_id=provider_id, path=path)


async def stat_file(ctx: RunContext[ChatDeps], provider_id: str, path: str) -> Any:
    """Get a file's or folder's metadata: size, modification time, and whether it is a folder.

    Use for questions about size, age, or existence of a known path.
    Do not use to read content; use read_file_excerpt.

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
    """Read lines of text from a file at a known path.

    Use when you need a file's exact wording, or a file that search_knowledge_base does not cover.
    Do not use to search across documents, or on folders or binary files.

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
    """Semantic search over the content of the user's indexed documents; returns matching passages.

    Use when the answer depends on what the user's documents say.
    Do not use for greetings, small talk, general knowledge, or finding files by name; use search_files.

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


def _errors_to_model(tool: Callable[..., Awaitable[Any]]) -> Callable[..., Awaitable[Any]]:
    """Report a tool's exception to the model as a failed tool call, so it can explain it instead of the turn aborting."""

    @functools.wraps(tool)
    async def wrapper(*args: Any, **kwargs: Any) -> Any:
        try:
            return await tool(*args, **kwargs)
        except ToolFailed:
            raise
        except Exception as exc:
            logger.warning("tool %s failed: %s", tool.__name__, exc)
            raise ToolFailed(str(exc)) from exc

    return wrapper


BASE_TOOLS: list[Callable[..., Any]] = [_errors_to_model(search_knowledge_base)]
FILE_TOOLS: list[Callable[..., Any]] = [
    _errors_to_model(tool) for tool in (search_files, list_directory, stat_file, read_file_excerpt)
]
