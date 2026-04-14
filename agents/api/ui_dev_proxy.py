from starlette.applications import Starlette
from starlette.responses import RedirectResponse
from starlette.routing import Route


def create_ui_dev_proxy(target_base_url: str) -> Starlette:
    base_url = target_base_url.rstrip("/")

    async def proxy_root(request) -> RedirectResponse:
        return RedirectResponse(f"{base_url}{request.url.path.removeprefix('/ui-dev') or '/'}")

    async def proxy_path(request) -> RedirectResponse:
        path = request.path_params["path"]
        query = f"?{request.url.query}" if request.url.query else ""
        suffix = f"/{path}" if path else "/"
        return RedirectResponse(f"{base_url}{suffix}{query}")

    return Starlette(routes=[Route("/", proxy_root), Route("/{path:path}", proxy_path)])
