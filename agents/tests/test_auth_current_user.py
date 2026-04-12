from collections.abc import Iterator
from contextlib import contextmanager

from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient
import pytest

from app.settings import get_settings
from auth.current_user import AuthenticatedUser, get_current_user


@contextmanager
def settings_env(monkeypatch: pytest.MonkeyPatch, **env: str) -> Iterator[None]:
    for key, value in env.items():
        monkeypatch.setenv(key, value)

    get_settings.cache_clear()
    try:
        yield
    finally:
        get_settings.cache_clear()


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


def test_current_user_defaults_to_anonymous_when_auth_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    app = FastAPI()

    with settings_env(monkeypatch, SERAPH_AUTH_ENABLED="false"):

        @app.get("/me")
        async def me(user: AuthenticatedUser = Depends(get_current_user)) -> dict[str, str]:
            return {"user_id": user.user_id}

        client = TestClient(app)
        response = client.get("/me")

        assert response.status_code == 200
        assert response.json() == {"user_id": "anonymous"}


def test_current_user_treats_blank_header_as_anonymous_when_auth_disabled(monkeypatch: pytest.MonkeyPatch) -> None:
    app = FastAPI()

    with settings_env(monkeypatch, SERAPH_AUTH_ENABLED="false"):

        @app.get("/me")
        async def me(user: AuthenticatedUser = Depends(get_current_user)) -> dict[str, str]:
            return {"user_id": user.user_id}

        client = TestClient(app)
        response = client.get("/me", headers={"X-Seraph-User": "   "})

        assert response.status_code == 200
        assert response.json() == {"user_id": "anonymous"}


def test_current_user_reads_configured_seraph_header(monkeypatch: pytest.MonkeyPatch) -> None:
    app = FastAPI()

    with settings_env(monkeypatch, SERAPH_AUTH_USER_HEADER="X-Custom-User"):

        @app.get("/me")
        async def me(user: AuthenticatedUser = Depends(get_current_user)) -> dict[str, str]:
            return {"user_id": user.user_id}

        client = TestClient(app)
        response = client.get("/me", headers={"X-Custom-User": "alice"})

        assert response.status_code == 200
        assert response.json() == {"user_id": "alice"}


def test_current_user_uses_default_header_when_configured_header_is_blank(monkeypatch: pytest.MonkeyPatch) -> None:
    app = FastAPI()

    with settings_env(monkeypatch, SERAPH_AUTH_USER_HEADER="   "):

        @app.get("/me")
        async def me(user: AuthenticatedUser = Depends(get_current_user)) -> dict[str, str]:
            return {"user_id": user.user_id}

        client = TestClient(app)
        response = client.get("/me", headers={"X-Seraph-User": "alice"})

        assert response.status_code == 200
        assert response.json() == {"user_id": "alice"}
