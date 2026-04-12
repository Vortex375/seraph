import sys
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.append(str(Path(__file__).resolve().parents[1]))

from app.main import create_app
from app.settings import Settings


def test_create_app_exposes_health_endpoint() -> None:
    app = create_app()

    with TestClient(app) as client:
        response = client.get("/healthz")

        assert response.status_code == 200
        assert response.json() == {"status": "ok"}
        assert isinstance(app.state.settings, Settings)
