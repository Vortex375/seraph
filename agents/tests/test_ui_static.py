import sys
from pathlib import Path

from fastapi.testclient import TestClient

sys.path.append(str(Path(__file__).resolve().parents[1]))

from app.main import create_app


def test_root_serves_chat_ui() -> None:
    client = TestClient(create_app())

    response = client.get("/")

    assert response.status_code == 200
    assert "Seraph Chat" in response.text


def test_ui_bundle_is_served() -> None:
    client = TestClient(create_app())

    response = client.get("/ui/app.js")

    assert response.status_code == 200
    assert "mountApp(root)" in response.text
