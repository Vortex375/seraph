from collections.abc import Awaitable, Callable, Sequence
from typing import Protocol

from retrieval.repository import RetrievalRepository, RetrievalResult
from spaces.access import SpaceScope


class EmbeddingResponse(Protocol):
    embeddings: Sequence[Sequence[float]]


class RetrievalService:
    def __init__(
        self, embedder: Callable[[list[str]], Awaitable[EmbeddingResponse]], repo: RetrievalRepository
    ) -> None:
        self._embedder = embedder
        self._repo = repo

    async def retrieve(self, query: str, scopes: list[SpaceScope], limit: int = 5) -> list[RetrievalResult]:
        embedding_response = await self._embedder([query])
        if not embedding_response.embeddings or not embedding_response.embeddings[0]:
            raise ValueError("missing query embedding")

        allowed_scopes = [(scope.provider_id, scope.path_prefix) for scope in scopes]
        return await self._repo.search(list(embedding_response.embeddings[0]), allowed_scopes, limit)
