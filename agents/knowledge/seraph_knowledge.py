from dataclasses import dataclass, field
from typing import Any

from agentscope.rag import KnowledgeBase
from agentscope.rag._document import DocMetadata, Document


@dataclass(frozen=True)
class SeraphChunkProvenance:
    provider_id: str
    path: str


@dataclass
class SeraphKnowledgeDocument(Document):
    provenance: SeraphChunkProvenance = field(default_factory=lambda: SeraphChunkProvenance(provider_id="", path=""))


class SeraphKnowledgeBase(KnowledgeBase):
    def __init__(
        self, embedding_store: Any, embedding_model: Any, retrieval_service: Any, spaces_client: Any, user_id: str
    ) -> None:
        super().__init__(embedding_store=embedding_store, embedding_model=embedding_model)
        self._retrieval_service = retrieval_service
        self._spaces_client = spaces_client
        self._user_id = user_id

    async def retrieve(  # type: ignore[override]
        self,
        query: str,
        limit: int = 5,
        score_threshold: float | None = None,
        **kwargs: Any,
    ) -> list[SeraphKnowledgeDocument]:
        del kwargs
        scopes = await self._spaces_client.get_scopes_for_user(self._user_id)
        results = await self._retrieval_service.retrieve(query=query, scopes=scopes, limit=limit)
        documents: list[SeraphKnowledgeDocument] = []
        for result in results:
            if score_threshold is not None and result.score < score_threshold:
                continue
            documents.append(
                SeraphKnowledgeDocument(
                    id=result.chunk_id,
                    score=result.score,
                    provenance=SeraphChunkProvenance(provider_id=result.provider_id, path=result.path),
                    metadata=DocMetadata(
                        content={"type": "text", "text": result.content},
                        doc_id=result.document_id,
                        chunk_id=result.chunk_index,
                        total_chunks=result.total_chunks,
                    ),
                )
            )
        return documents

    async def add_documents(self, documents: list[Document], **kwargs: Any) -> None:
        del documents, kwargs
        return None
