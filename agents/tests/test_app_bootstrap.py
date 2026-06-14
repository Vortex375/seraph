from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.main import create_app, initialize_database_schema


@pytest.mark.asyncio
async def test_initialize_database_schema_creates_all_tables(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[object] = []

    def fake_create_all(bind: object) -> None:
        calls.append(bind)

    class FakeConn:
        async def run_sync(self, fn: Any, *args: Any, **kwargs: Any) -> Any:
            class FakeSyncConn:
                def execute(self, statement: object, *params: Any, **kw: Any) -> Any:
                    del statement, params, kw
                    return None

            return fn(FakeSyncConn(), *args, **kwargs)

    class FakeEngine:
        def begin(self) -> Any:
            class Ctx:
                async def __aenter__(self) -> FakeConn:
                    return FakeConn()

                async def __aexit__(self, *args: Any) -> None:
                    del args
                    return None

            return Ctx()

    monkeypatch.setattr("app.main.Base.metadata.create_all", fake_create_all)
    monkeypatch.setattr("app.main.engine", FakeEngine())
    await initialize_database_schema()
    assert len(calls) == 1


def test_create_app_exposes_health_endpoint() -> None:
    app = create_app()
    client = TestClient(app)
    try:
        response = client.get("/healthz")
    finally:
        client.close()

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
