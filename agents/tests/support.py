"""Test doubles shared by the chat tests."""

from collections.abc import AsyncIterator
from typing import Any

from pydantic_ai import ModelMessage, ToolReturnPart
from pydantic_ai.models.function import AgentInfo, DeltaToolCall

from retrieval.repository import RetrievalResult
from spaces.access import SpaceScope


SPEC_CITATION = {"provider_id": "space-a", "path": "/team/spec.md", "label": "/team/spec.md"}


async def search_then_answer(messages: list[ModelMessage], info: AgentInfo) -> AsyncIterator[Any]:
    """Call the knowledge tool once, then answer in two chunks."""
    del info
    if not any(isinstance(part, ToolReturnPart) for message in messages for part in message.parts):
        yield {0: DeltaToolCall(name="search_knowledge_base", json_args='{"query": "launch"}')}
        return
    yield "July "
    yield "first"


class StubRetrieval:
    """Returns one fixed chunk for every query; ``results`` can be replaced per test."""

    def __init__(self) -> None:
        self.results = [
            RetrievalResult(
                chunk_id="chunk-1",
                document_id="doc-1",
                provider_id="space-a",
                path="/team/spec.md",
                content="The launch date is 2026-07-01.",
                score=0.9,
                chunk_index=0,
                total_chunks=1,
            )
        ]

    async def retrieve(self, query: str, scopes: list[SpaceScope], limit: int = 5) -> list[RetrievalResult]:
        return self.results


class StubSpaces:
    def __init__(self, scopes: list[SpaceScope] | None = None) -> None:
        self.scopes = scopes or [SpaceScope(provider_id="space-a", path_prefix="/")]

    async def get_scopes_for_user(self, user_id: str) -> list[SpaceScope]:
        return self.scopes
