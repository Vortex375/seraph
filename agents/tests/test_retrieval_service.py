import sys
from pathlib import Path

import pytest

sys.path.append(str(Path(__file__).resolve().parents[1]))

from retrieval.repository import RetrievalResult
from retrieval.service import RetrievalService
from spaces.client import SpacesClient
from spaces.access import SpaceScope


class StubEmbedder:
    async def __call__(self, values: list[str]):
        assert values == ["project plan"]
        return type("EmbeddingResponse", (), {"embeddings": [[0.1, 0.2, 0.3]]})()


class StubRepository:
    async def search(self, embedding: list[float], scopes: list[tuple[str, str]], limit: int):
        assert embedding == [0.1, 0.2, 0.3]
        assert scopes == [("provider-a", "/team/docs")]
        assert limit == 5
        return [
            RetrievalResult(
                document_id="doc-1",
                chunk_id="chunk-1",
                chunk_index=2,
                total_chunks=4,
                provider_id="provider-a",
                path="/team/docs/plan.md",
                content="project plan body",
                score=0.91,
            )
        ]


@pytest.mark.asyncio
async def test_retrieval_only_returns_chunks_inside_visible_spaces() -> None:
    service = RetrievalService(embedder=StubEmbedder(), repo=StubRepository())

    results = await service.retrieve(
        query="project plan",
        scopes=[SpaceScope(provider_id="provider-a", path_prefix="/team/docs")],
        limit=5,
    )

    assert all(result.provider_id == "provider-a" for result in results)
    assert all(result.path.startswith("/team/docs") for result in results)
    assert results[0].chunk_index == 2
    assert results[0].total_chunks == 4


class EmptyEmbeddingResponse:
    embeddings: list[list[float]] = []


class EmptyEmbedder:
    async def __call__(self, values: list[str]):
        assert values == ["project plan"]
        return EmptyEmbeddingResponse()


@pytest.mark.asyncio
async def test_retrieve_rejects_missing_embeddings() -> None:
    service = RetrievalService(embedder=EmptyEmbedder(), repo=StubRepository())

    with pytest.raises(ValueError, match="missing query embedding"):
        await service.retrieve(
            query="project plan",
            scopes=[SpaceScope(provider_id="provider-a", path_prefix="/team/docs")],
            limit=5,
        )


def test_spaces_client_accepts_empty_root_path() -> None:
    scope = SpacesClient._scope_from_provider({"providerId": "provider-a", "path": ""})

    assert scope == SpaceScope(provider_id="provider-a", path_prefix="/")


def test_spaces_client_rejects_none_provider_or_path() -> None:
    assert SpacesClient._scope_from_provider({"providerId": None, "path": "/team/docs"}) is None
    assert SpacesClient._scope_from_provider({"providerId": "provider-a", "path": None}) is None
