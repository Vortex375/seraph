import sys
from pathlib import Path

from agentscope.rag._document import Document
import pytest

sys.path.append(str(Path(__file__).resolve().parents[1]))

from knowledge.seraph_knowledge import SeraphKnowledgeBase, SeraphKnowledgeDocument
from retrieval.repository import RetrievalResult
from spaces.access import SpaceScope


class StubSpacesClient:
    async def get_scopes_for_user(self, user_id: str):
        assert user_id == "alice"
        return [SpaceScope(provider_id="provider-a", path_prefix="/team/docs")]


class StubRetrievalService:
    async def retrieve(self, query: str, scopes, limit: int = 5):
        assert query == "release notes"
        assert scopes == [SpaceScope(provider_id="provider-a", path_prefix="/team/docs")]
        assert limit == 3
        return [
            RetrievalResult(
                document_id="doc-1",
                chunk_id="chunk-1",
                chunk_index=2,
                total_chunks=4,
                provider_id="provider-a",
                path="/team/docs/release.md",
                content="release notes body",
                score=0.95,
            )
        ]


@pytest.mark.asyncio
async def test_seraph_knowledge_returns_agentscope_documents_with_provenance() -> None:
    knowledge = SeraphKnowledgeBase(
        embedding_store=None,
        embedding_model=None,
        retrieval_service=StubRetrievalService(),
        spaces_client=StubSpacesClient(),
        user_id="alice",
    )

    docs = await knowledge.retrieve("release notes", limit=3)

    assert len(docs) == 1
    doc = docs[0]
    assert isinstance(doc, Document)
    assert isinstance(doc, SeraphKnowledgeDocument)
    typed_docs: list[SeraphKnowledgeDocument] = docs
    assert typed_docs[0] is doc
    text_content = doc.metadata.content
    assert text_content["type"] == "text"
    typed_content = text_content
    assert typed_content["text"] == "release notes body"
    assert doc.metadata.doc_id == "doc-1"
    assert doc.metadata.chunk_id == 2
    assert doc.metadata.total_chunks == 4
    assert doc.id == "chunk-1"
    assert doc.provenance.path == "/team/docs/release.md"
    assert doc.provenance.provider_id == "provider-a"


@pytest.mark.asyncio
async def test_seraph_knowledge_preserves_root_scope_provenance() -> None:
    class RootSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            assert user_id == "alice"
            return [SpaceScope(provider_id="provider-a", path_prefix="/")]

    class RootRetrievalService:
        async def retrieve(self, query: str, scopes, limit: int = 5):
            assert query == "release notes"
            assert scopes == [SpaceScope(provider_id="provider-a", path_prefix="/")]
            assert limit == 3
            return [
                RetrievalResult(
                    document_id="doc-root",
                    chunk_id="chunk-root",
                    chunk_index=0,
                    total_chunks=1,
                    provider_id="provider-a",
                    path="/release.md",
                    content="root release notes",
                    score=0.9,
                )
            ]

    knowledge = SeraphKnowledgeBase(
        embedding_store=None,
        embedding_model=None,
        retrieval_service=RootRetrievalService(),
        spaces_client=RootSpacesClient(),
        user_id="alice",
    )

    docs = await knowledge.retrieve("release notes", limit=3)

    assert len(docs) == 1
    doc = docs[0]
    assert isinstance(doc, SeraphKnowledgeDocument)
    assert doc.provenance.path == "/release.md"
    assert doc.provenance.provider_id == "provider-a"


@pytest.mark.asyncio
async def test_seraph_knowledge_applies_score_threshold() -> None:
    knowledge = SeraphKnowledgeBase(
        embedding_store=None,
        embedding_model=None,
        retrieval_service=StubRetrievalService(),
        spaces_client=StubSpacesClient(),
        user_id="alice",
    )

    docs = await knowledge.retrieve("release notes", limit=3, score_threshold=0.99)

    assert docs == []
