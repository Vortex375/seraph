from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from retrieval.repository import RetrievalResult


@dataclass(frozen=True)
class SeraphChunkProvenance:
    provider_id: str
    path: str


@dataclass
class SeraphKnowledgeDocument:
    id: str
    score: float
    provenance: SeraphChunkProvenance
    content: str
    document_id: str = ""
    chunk_index: int = 0
    total_chunks: int = 1


class SeraphKnowledgeBase:
    """Plain search adapter over RetrievalService and spaces authorization.

    This class is *not* an AgentScope KnowledgeBase; in AgentScope 2.x the
    ``agentscope.rag`` module was removed. It only exposes ``search`` so the
    chat agent's ``search_knowledge_base`` tool can perform scoped semantic
    retrieval when the model decides to look up documents.
    """

    def __init__(
        self, retrieval_service: Any, spaces_client: Any, user_id: str
    ) -> None:
        self._retrieval_service = retrieval_service
        self._spaces_client = spaces_client
        self._user_id = user_id

    async def search(
        self, query: str, limit: int = 5, min_score: float = 0.0
    ) -> list[SeraphKnowledgeDocument]:
        scopes = await self._spaces_client.get_scopes_for_user(self._user_id)
        results = await self._retrieval_service.retrieve(query=query, scopes=scopes, limit=limit)
        documents: list[SeraphKnowledgeDocument] = []
        for result in results:
            if min_score and result.score < min_score:
                continue
            documents.append(_result_to_document(result))
        return documents


def _result_to_document(result: RetrievalResult) -> SeraphKnowledgeDocument:
    return SeraphKnowledgeDocument(
        id=result.chunk_id,
        score=result.score,
        provenance=SeraphChunkProvenance(provider_id=result.provider_id, path=result.path),
        content=_format_prompt_visible_content(result.path, result.content),
        document_id=result.document_id,
        chunk_index=result.chunk_index,
        total_chunks=result.total_chunks,
    )


def _format_prompt_visible_content(path: str, content: str) -> str:
    return f"Path: {path}\n\n{content}"
