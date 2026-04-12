import json
from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any

from nats.aio.client import Client as NatsClient

from spaces.access import SpaceScope

SPACE_CRUD_TOPIC = "seraph.spaces.crud"


@dataclass(frozen=True)
class SpacesClient:
    nc: NatsClient

    @staticmethod
    def _normalize_scope_path(value: str) -> str:
        if not value:
            return "/"

        normalized = value if value.startswith("/") else f"/{value}"
        canonical_parts: list[str] = []
        for part in PurePosixPath(normalized).parts:
            if part in ("", "/", "."):
                continue
            if part == "..":
                raise ValueError("space path escapes root")
            canonical_parts.append(part)

        if not canonical_parts:
            return "/"

        return "/" + "/".join(canonical_parts)

    @classmethod
    def _scope_from_provider(cls, provider: dict[str, Any]) -> SpaceScope | None:
        provider_id_value = provider.get("providerId")
        path_value = provider.get("path") if "path" in provider else None
        if provider_id_value is None or path_value is None:
            return None

        provider_id = str(provider_id_value).strip()
        if not provider_id:
            return None

        raw_path = str(path_value).strip()

        return SpaceScope(provider_id=provider_id, path_prefix=cls._normalize_scope_path(raw_path))

    async def get_scopes_for_user(self, user_id: str) -> list[SpaceScope]:
        payload = {
            "operation": "READ",
            "space": {
                "users": [user_id],
            },
        }
        msg = await self.nc.request(SPACE_CRUD_TOPIC, json.dumps(payload).encode("utf-8"), timeout=5.0)
        response = json.loads(msg.data.decode("utf-8"))

        scope_map: dict[tuple[str, str], SpaceScope] = {}
        for space in response.get("space", []):
            for provider in space.get("fileProviders", []):
                scope = self._scope_from_provider(provider)
                if scope is None:
                    continue
                scope_map[(scope.provider_id, scope.path_prefix)] = scope

        return list(scope_map.values())
