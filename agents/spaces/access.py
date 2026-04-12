from dataclasses import dataclass
from pathlib import PurePosixPath
from typing import Any


@dataclass(frozen=True)
class SpaceScope:
    provider_id: str
    path_prefix: str


def _normalize_path(value: str) -> str:
    if not value:
        return "/"

    normalized = value if value.startswith("/") else f"/{value}"
    canonical_parts: list[str] = []
    for part in PurePosixPath(normalized).parts:
        if part in ("", "/"):
            continue
        if part == ".":
            continue
        if part == "..":
            raise ValueError("path escapes scope")
        canonical_parts.append(part)

    if not canonical_parts:
        return "/"

    return "/" + "/".join(canonical_parts)


def _path_allowed(path_prefix: str, path: str) -> bool:
    try:
        normalized_prefix = _normalize_path(path_prefix)
        normalized_path = _normalize_path(path)
    except ValueError:
        return False

    return normalized_path == normalized_prefix or normalized_path.startswith(normalized_prefix + "/")


def filter_allowed_documents(scopes: list[SpaceScope], documents: list[dict[str, Any]]) -> list[dict[str, Any]]:
    return [
        document
        for document in documents
        if any(
            scope.provider_id == document.get("provider_id")
            and _path_allowed(scope.path_prefix, str(document.get("path", "")))
            for scope in scopes
        )
    ]
