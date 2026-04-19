from __future__ import annotations

import os
from itertools import islice
from typing import Any, Callable

from chat.file_models import FileCitation, FileEntry, FileReadExcerpt
from spaces.access import _normalize_path, _path_allowed


class AgentFileAccessService:
    def __init__(
        self,
        *,
        spaces_client: Any,
        file_provider_factory: Callable[[str], Any],
        search_client: Any,
        max_read_bytes: int = 128 * 1024,
        max_inline_file_size: int = 256 * 1024,
    ) -> None:
        self._spaces_client = spaces_client
        self._file_provider_factory = file_provider_factory
        self._search_client = search_client
        self._max_read_bytes = max_read_bytes
        self._max_inline_file_size = max_inline_file_size

    async def search_files(self, *, user_id: str, query: str) -> list[dict[str, str]]:
        if self._search_client is None:
            return []
        hits = await self._search_client.search_files(user_id=user_id, query=query)
        return [self._citation(hit.provider_id, hit.path).to_dict() for hit in hits]

    async def list_directory(self, *, user_id: str, provider_id: str, path: str) -> list[dict[str, Any]]:
        normalized = await self._authorize(user_id=user_id, provider_id=provider_id, path=path)
        client = self._file_provider_factory(provider_id)
        handle = await client.open_file(normalized, os.O_RDONLY, 0)
        try:
            entries = await handle.readdir(0)
        finally:
            await handle.close()

        return [
            FileEntry(
                provider_id=provider_id,
                path=_normalize_path(f"{normalized.rstrip('/')}/{entry.name}"),
                name=entry.name,
                size=entry.size,
                mod_time=entry.mod_time,
                is_dir=entry.is_dir,
            ).to_dict()
            for entry in entries
        ]

    async def stat_file(self, *, user_id: str, provider_id: str, path: str) -> dict[str, Any]:
        normalized = await self._authorize(user_id=user_id, provider_id=provider_id, path=path)
        client = self._file_provider_factory(provider_id)
        info = await client.stat(normalized)
        return FileEntry(
            provider_id=provider_id,
            path=normalized,
            name=info.name,
            size=info.size,
            mod_time=info.mod_time,
            is_dir=info.is_dir,
        ).to_dict()

    async def read_file_excerpt(
        self,
        *,
        user_id: str,
        provider_id: str,
        path: str,
        start_line: int = 1,
        max_lines: int = 80,
        max_chars: int = 12000,
    ) -> dict[str, Any]:
        normalized = await self._authorize(user_id=user_id, provider_id=provider_id, path=path)
        client = self._file_provider_factory(provider_id)
        info = await client.stat(normalized)
        reference = self._citation(provider_id, normalized)

        if info.is_dir:
            return FileReadExcerpt(
                reference=reference,
                content=None,
                message="That path is a directory.",
                start_line=max(start_line, 1),
                end_line=None,
                truncated=False,
            ).to_dict()
        if info.size > self._max_inline_file_size:
            return FileReadExcerpt(
                reference=reference,
                content=None,
                message="That file is too large to read inline.",
                start_line=max(start_line, 1),
                end_line=None,
                truncated=False,
            ).to_dict()

        handle = await client.open_file(normalized, os.O_RDONLY, 0)
        try:
            text, truncated_by_window = await self._read_text_window(
                handle,
                start_line=max(start_line, 1),
                max_lines=max(max_lines, 1),
            )
        finally:
            await handle.close()

        if text is None:
            return FileReadExcerpt(
                reference=reference,
                content=None,
                message="I can inspect metadata but can't read that file as text.",
                start_line=max(start_line, 1),
                end_line=None,
                truncated=False,
            ).to_dict()

        excerpt_start = max(start_line, 1)
        excerpt_lines = text.splitlines()
        excerpt = text
        truncated = truncated_by_window
        if len(excerpt) > max_chars:
            excerpt = excerpt[:max_chars].rstrip()
            truncated = True
            excerpt_lines = excerpt.splitlines()
        end_line = excerpt_start + len(excerpt_lines) - 1 if excerpt_lines else None
        return FileReadExcerpt(
            reference=reference,
            content=excerpt,
            message=None,
            start_line=excerpt_start,
            end_line=end_line,
            truncated=truncated,
        ).to_dict()

    async def _read_text_window(self, handle: Any, *, start_line: int, max_lines: int) -> tuple[str | None, bool]:
        skipped = 0
        buffered_lines: list[str] = []
        tail = b""
        chunk_index = 0
        truncated = False

        while len(buffered_lines) < max_lines:
            if hasattr(handle, "seek"):
                await handle.seek(chunk_index * self._max_read_bytes, os.SEEK_SET)
            try:
                payload = await handle.read(self._max_read_bytes)
            except EOFError:
                break
            if not payload:
                break
            chunk_index += 1
            try:
                decoded = (tail + payload).decode("utf-8")
                tail = b""
            except UnicodeDecodeError:
                if chunk_index == 1:
                    return None, False
                truncated = True
                break

            lines = decoded.splitlines(keepends=True)
            if decoded and not decoded.endswith(("\n", "\r")):
                tail = lines.pop().encode("utf-8") if lines else decoded.encode("utf-8")
            for line in lines:
                skipped += 1
                if skipped < start_line:
                    continue
                buffered_lines.append(line.rstrip("\r\n"))
                if len(buffered_lines) == max_lines:
                    break
            if len(buffered_lines) < max_lines and chunk_index * self._max_read_bytes >= self._max_inline_file_size:
                truncated = True
                break

        if tail and len(buffered_lines) < max_lines:
            try:
                decoded_tail = tail.decode("utf-8")
            except UnicodeDecodeError:
                return None, False
            skipped += 1
            if skipped >= start_line:
                buffered_lines.append(decoded_tail.rstrip("\r\n"))

        return "\n".join(islice(buffered_lines, 0, max_lines)), truncated

    async def _authorize(self, *, user_id: str, provider_id: str, path: str) -> str:
        normalized = _normalize_path(path)
        scopes = await self._spaces_client.get_scopes_for_user(user_id)
        for scope in scopes:
            normalized_prefix = _normalize_path(scope.path_prefix)
            allowed = normalized_prefix == "/" or _path_allowed(normalized_prefix, normalized)
            if scope.provider_id == provider_id and allowed:
                return normalized
        raise PermissionError("requested path is outside accessible scopes")

    def _citation(self, provider_id: str, path: str) -> FileCitation:
        return FileCitation(provider_id=provider_id, path=path, label=path)
