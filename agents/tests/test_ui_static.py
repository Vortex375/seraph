import sys
from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.middleware import Middleware
from starlette.middleware.base import BaseHTTPMiddleware

sys.path.append(str(Path(__file__).resolve().parents[1]))

from app.main import create_app
from app.settings import get_settings


def test_root_serves_chat_ui() -> None:
    client = TestClient(create_app())

    response = client.get("/")

    assert response.status_code == 200
    assert '<div id="root"></div>' in response.text
    assert "/ui/assets/" in response.text


def test_ui_bundle_is_served() -> None:
    client = TestClient(create_app())

    index_response = client.get("/")
    asset_path = next(
        part.split('"')[0] for part in index_response.text.split('src="') if part.startswith("/ui/assets/")
    )

    response = client.get(asset_path)

    assert response.status_code == 200
    assert "React" in response.text or "createRoot" in response.text


def test_root_proxies_to_vite_in_dev_mode(monkeypatch) -> None:
    monkeypatch.setenv("RUNTIME_ENV", "dev")
    monkeypatch.setenv("UI_DEV_SERVER_URL", "http://127.0.0.1:5173")
    get_settings.cache_clear()

    class CaptureProxyMiddleware(BaseHTTPMiddleware):
        async def dispatch(self, request, call_next):
            response = await call_next(request)
            response.headers["x-proxy-path"] = str(request.url.path)
            return response

    app = create_app()
    middleware = [Middleware(CaptureProxyMiddleware)]
    proxy_app = FastAPI(middleware=middleware)

    @proxy_app.get("/{path:path}")
    async def proxied(path: str):
        return {"path": path}

    app.mount("/ui-dev", proxy_app)

    client = TestClient(app)
    response = client.get("/", follow_redirects=False)

    assert response.status_code == 307
    assert response.headers["location"] == "/ui-dev/"
    get_settings.cache_clear()


def test_session_preview_styles_are_single_line_and_ellipsized() -> None:
    stylesheet = (Path(__file__).resolve().parents[1] / "ui" / "src" / "styles.css").read_text()

    assert ".session-row__preview" in stylesheet
    assert "white-space: nowrap;" in stylesheet
    assert "overflow: hidden;" in stylesheet
    assert "text-overflow: ellipsis;" in stylesheet


def test_vite_config_proxies_api_and_stream_requests_to_fastapi() -> None:
    vite_config = (Path(__file__).resolve().parents[1] / "ui" / "vite.config.ts").read_text()

    assert "'/api'" in vite_config or '"/api"' in vite_config
    assert "target:" in vite_config
    assert "8000" in vite_config
