from dataclasses import dataclass

from fastapi import Header, HTTPException, status


@dataclass(frozen=True)
class AuthenticatedUser:
    user_id: str


async def get_current_user(
    x_seraph_user: str | None = Header(default=None, alias="X-Seraph-User"),
) -> AuthenticatedUser:
    user_id = x_seraph_user.strip() if x_seraph_user is not None else None
    if not user_id:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="missing authenticated user")

    return AuthenticatedUser(user_id=user_id)
