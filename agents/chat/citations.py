from __future__ import annotations

from typing import Any

from sqlalchemy import select

from documents.models import ChatTurnFailure, ChatTurnSource
from knowledge.seraph_knowledge import SeraphKnowledgeDocument


async def record_sources(db: Any, *, session_id: str, assistant_message_id: str, sources: list[dict[str, str]]) -> None:
    unique_sources = {
        (source.get("provider_id", ""), source.get("path", ""))
        for source in sources
        if source.get("provider_id") and source.get("path")
    }
    if not unique_sources:
        return None

    try:
        result = await db.execute(
            select(ChatTurnSource).where(
                ChatTurnSource.session_id == session_id,
                ChatTurnSource.assistant_message_id == assistant_message_id,
            )
        )
        existing = {(row.provider_id, row.path) for row in result.scalars().all()}
        for provider_id, path in sorted(unique_sources - existing):
            db.add(
                ChatTurnSource(
                    session_id=session_id,
                    assistant_message_id=assistant_message_id,
                    provider_id=provider_id,
                    path=path,
                )
            )
        await db.commit()
    except BaseException:
        await db.rollback()
        raise


async def record_failure(db: Any, *, session_id: str, assistant_message_id: str, error: str) -> None:
    try:
        await db.rollback()
    except BaseException:
        pass

    try:
        db.add(
            ChatTurnFailure(
                session_id=session_id,
                assistant_message_id=assistant_message_id,
                error=error,
            )
        )
        await db.commit()
    except BaseException:
        await db.rollback()
        raise


def sources_from_knowledge_documents(documents: list[Any]) -> list[dict[str, str]]:
    sources: list[dict[str, str]] = []
    for document in documents:
        if not isinstance(document, SeraphKnowledgeDocument):
            continue
        provider_id = document.provenance.provider_id
        path = document.provenance.path
        if provider_id and path:
            sources.append({"provider_id": provider_id, "path": path})
    return sources
