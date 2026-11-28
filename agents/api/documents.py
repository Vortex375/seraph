from typing import Annotated

from fastapi import APIRouter, Depends, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from api.models import DocumentStatusResponse
from auth.current_user import AuthenticatedUser, get_current_user
from db.session import get_db_session
from documents.models import IndexedDocument
from knowledge.seraph_knowledge import ScopeProvider
from spaces.access import _path_allowed

router = APIRouter(prefix="/api/v1/documents", tags=["documents"])


def get_spaces_client(request: Request) -> ScopeProvider:
    spaces_client: ScopeProvider = request.app.state.spaces_client
    return spaces_client


@router.get("/status", response_model=list[DocumentStatusResponse])
async def document_status(
    user: Annotated[AuthenticatedUser, Depends(get_current_user)],
    db: Annotated[AsyncSession, Depends(get_db_session)],
    spaces_client: Annotated[ScopeProvider, Depends(get_spaces_client)],
) -> list[DocumentStatusResponse]:
    documents = (await db.scalars(select(IndexedDocument).order_by(IndexedDocument.path.asc()))).all()
    scopes = await spaces_client.get_scopes_for_user(user.user_id)
    return [
        DocumentStatusResponse.model_validate(document)
        for document in documents
        if any(
            scope.provider_id == document.provider_id and _path_allowed(scope.path_prefix, document.path)
            for scope in scopes
        )
    ]
