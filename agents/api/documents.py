from typing import Any

from fastapi import APIRouter, Depends, Request
from sqlalchemy import select

from api.models import DocumentStatusResponse
from auth.current_user import AuthenticatedUser, get_current_user
from db.session import get_db_session
from documents.models import IndexedDocument
from spaces.access import _path_allowed

router = APIRouter(prefix="/api/v1/documents", tags=["documents"])


@router.get("/status", response_model=list[DocumentStatusResponse])
async def document_status(
    request: Request,
    user: AuthenticatedUser = Depends(get_current_user),
    db: Any = Depends(get_db_session),
) -> list[DocumentStatusResponse]:
    result = await db.execute(select(IndexedDocument).order_by(IndexedDocument.path.asc()))
    documents = result.scalars().all()
    spaces_client = request.app.state.spaces_client
    scopes = await spaces_client.get_scopes_for_user(user.user_id)
    filtered_documents = [
        document
        for document in documents
        if any(
            scope.provider_id == document.provider_id and _path_allowed(scope.path_prefix, document.path)
            for scope in scopes
        )
    ]
    return [DocumentStatusResponse.model_validate(document) for document in filtered_documents]
