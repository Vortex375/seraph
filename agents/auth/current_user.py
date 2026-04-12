from dataclasses import dataclass

from fastapi import HTTPException, Request, status

from app.settings import get_settings


DEFAULT_SERAPH_AUTH_USER_HEADER = "X-Seraph-User"


@dataclass(frozen=True)
class AuthenticatedUser:
    user_id: str


async def get_current_user(
    request: Request,
) -> AuthenticatedUser:
    settings = get_settings()
    header_name = settings.seraph_auth_user_header.strip() or DEFAULT_SERAPH_AUTH_USER_HEADER
    user_header = request.headers.get(header_name)
    user_id = user_header.strip() if user_header is not None else None
    if user_id:
        return AuthenticatedUser(user_id=user_id)

    if not settings.seraph_auth_enabled:
        return AuthenticatedUser(user_id="anonymous")

    raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="missing authenticated user")
