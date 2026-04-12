from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient

from auth.current_user import AuthenticatedUser, get_current_user


def test_current_user_reads_seraph_header() -> None:
    app = FastAPI()

    @app.get("/me")
    async def me(user: AuthenticatedUser = Depends(get_current_user)) -> dict[str, str]:
        return {"user_id": user.user_id}

    client = TestClient(app)
    response = client.get("/me", headers={"X-Seraph-User": "alice"})

    assert response.status_code == 200
    assert response.json() == {"user_id": "alice"}


def test_current_user_rejects_blank_seraph_header() -> None:
    app = FastAPI()

    @app.get("/me")
    async def me(user: AuthenticatedUser = Depends(get_current_user)) -> dict[str, str]:
        return {"user_id": user.user_id}

    client = TestClient(app)
    response = client.get("/me", headers={"X-Seraph-User": "   "})

    assert response.status_code == 401
    assert response.json() == {"detail": "missing authenticated user"}
