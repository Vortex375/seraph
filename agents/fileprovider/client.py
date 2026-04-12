"""Async NATS-based file provider client implementation."""

from __future__ import annotations

import asyncio
import logging
import os
import posixpath
import uuid
from dataclasses import dataclass
from io import BytesIO
from typing import Any, Dict, List, Optional, cast

from cachetools import TTLCache
from fastavro import schemaless_reader, schemaless_writer
from nats.aio.client import Client as NatsClient

from fileprovider.messages import (
    FILE_PROVIDER_FILE_TOPIC_PREFIX,
    FILE_PROVIDER_READDIR_TOPIC_PREFIX,
    FILE_PROVIDER_TOPIC_PREFIX,
    SCHEMAS,
    decode_union,
    encode_union,
)
from fileprovider.trace_context import inject_trace_context

DEFAULT_TIMEOUT = 30.0
CACHE_TIMEOUT = 5.0
MAX_PAYLOAD = 768 * 1024


@dataclass(frozen=True)
class FileInfo:
    name: str
    size: int
    mode: int
    mod_time: int
    is_dir: bool


def _encode(schema: Any, payload: Dict[str, Any]) -> bytes:
    buffer = BytesIO()
    schemaless_writer(buffer, schema, payload)
    return buffer.getvalue()


def _decode(schema: Any, payload: bytes) -> Dict[str, Any]:
    buffer = BytesIO(payload)
    return cast(Dict[str, Any], schemaless_reader(buffer, schema, None))


def _io_error_to_exception(err: Dict[str, str]) -> Optional[Exception]:
    if not err or (err.get("error", "") == "" and err.get("class", "") == ""):
        return None

    err_class = err.get("class", "")
    err_msg = err.get("error", "") or "file provider error"

    if err_class == "EOF":
        return EOFError(err_msg)
    if err_class == "ErrInvalid":
        return ValueError(err_msg)
    if err_class == "ErrPermission":
        return PermissionError(err_msg)
    if err_class == "ErrExist":
        return FileExistsError(err_msg)
    if err_class == "ErrNotExist":
        return FileNotFoundError(err_msg)
    if err_class == "ErrClosed":
        return OSError(err_msg)
    return OSError(err_msg)


class FileProviderClient:
    def __init__(self, provider_id: str, nc: NatsClient, logger: Optional[logging.Logger] = None) -> None:
        self._provider_id = provider_id
        self._nc = nc
        self._log = logger or logging.getLogger(f"fileproviderclient.{provider_id}")
        self._cache: TTLCache[str, FileInfo] = TTLCache(maxsize=4096, ttl=CACHE_TIMEOUT)

    async def close(self) -> None:
        self._cache.clear()

    async def mkdir(self, name: str, perm: int) -> None:
        request = {
            "uid": str(uuid.uuid4()),
            "request": encode_union(
                "MkdirRequest",
                {"name": name, "perm": perm},
            ),
        }

        response = await self._exchange(request)
        _, payload = decode_union(response["response"])
        err = _io_error_to_exception(payload["error"])
        if err:
            self._log.error("mkdir failed", extra={"uid": request["uid"], "req": request["request"], "error": err})
            raise err

    async def open_file(self, name: str, flag: int, perm: int) -> "LazyAsyncFile":
        return LazyAsyncFile(client=self, name=name, flag=flag, perm=perm)

    async def _do_open_file(self, name: str, flag: int, perm: int) -> "AsyncFileHandle":
        request = {
            "uid": str(uuid.uuid4()),
            "request": encode_union(
                "OpenFileRequest",
                {"name": name, "flag": flag, "perm": perm},
            ),
        }

        response = await self._exchange(request)
        _, payload = decode_union(response["response"])
        err = _io_error_to_exception(payload["error"])
        if err:
            self._log.error("openFile failed", extra={"uid": request["uid"], "req": request["request"], "error": err})
            raise err

        return AsyncFileHandle(client=self, file_id=payload["fileId"], name=name, flag=flag, perm=perm)

    async def remove_all(self, name: str) -> None:
        request = {
            "uid": str(uuid.uuid4()),
            "request": encode_union(
                "RemoveAllRequest",
                {"name": name},
            ),
        }

        response = await self._exchange(request)
        _, payload = decode_union(response["response"])
        err = _io_error_to_exception(payload["error"])
        if err:
            self._log.error("removeAll failed", extra={"uid": request["uid"], "req": request["request"], "error": err})
            raise err

    async def rename(self, old_name: str, new_name: str) -> None:
        request = {
            "uid": str(uuid.uuid4()),
            "request": encode_union(
                "RenameRequest",
                {"oldName": old_name, "newName": new_name},
            ),
        }

        response = await self._exchange(request)
        _, payload = decode_union(response["response"])
        err = _io_error_to_exception(payload["error"])
        if err:
            self._log.error("rename failed", extra={"uid": request["uid"], "req": request["request"], "error": err})
            raise err

    async def stat(self, name: str) -> FileInfo:
        cached = self._cache.get(name)
        if cached is not None:
            return cached

        request = {
            "uid": str(uuid.uuid4()),
            "request": encode_union(
                "StatRequest",
                {"name": name},
            ),
        }

        response = await self._exchange(request)
        _, payload = decode_union(response["response"])
        err = _io_error_to_exception(payload["error"])
        if err:
            self._log.error("stat failed", extra={"uid": request["uid"], "req": request["request"], "error": err})
            raise err

        info = FileInfo(
            name=payload["name"],
            size=payload["size"],
            mode=payload["mode"],
            mod_time=payload["modTime"],
            is_dir=payload["isDir"],
        )
        self._cache[name] = info
        return info

    async def _exchange(self, request: Dict[str, Any]) -> Dict[str, Any]:
        payload = _encode(SCHEMAS["FileProviderRequest"], request)
        headers = inject_trace_context({})
        msg = await self._nc.request(
            FILE_PROVIDER_TOPIC_PREFIX + self._provider_id,
            payload,
            timeout=DEFAULT_TIMEOUT,
            headers=headers,
        )
        return _decode(SCHEMAS["FileProviderResponse"], msg.data)

    async def _exchange_file(self, request: Dict[str, Any], file_id: str) -> Dict[str, Any]:
        payload = _encode(SCHEMAS["FileProviderFileRequest"], request)
        headers = inject_trace_context({})
        msg = await self._nc.request(
            FILE_PROVIDER_FILE_TOPIC_PREFIX + file_id,
            payload,
            timeout=DEFAULT_TIMEOUT,
            headers=headers,
        )
        return _decode(SCHEMAS["FileProviderFileResponse"], msg.data)


class AsyncFileHandle:
    def __init__(self, client: FileProviderClient, file_id: str, name: str, flag: int, perm: int) -> None:
        self._client = client
        self._file_id = file_id
        self._name = name
        self._flag = flag
        self._perm = perm
        self._closed = False

    async def close(self) -> None:
        if self._closed:
            return

        request = {
            "uid": str(uuid.uuid4()),
            "fileId": self._file_id,
            "request": encode_union("FileCloseRequest", {}),
        }
        response = await self._client._exchange_file(request, self._file_id)
        _, payload = decode_union(response["response"])
        err = _io_error_to_exception(payload["error"])
        if err:
            self._client._log.error(
                "fileClose failed",
                extra={"uid": request["uid"], "req": request["request"], "error": err},
            )
            raise err

        self._closed = True

    async def read(self, size: int) -> bytes:
        if size <= 0:
            return b""

        if size <= MAX_PAYLOAD:
            return await self._do_read(size)

        parts: List[bytes] = []
        remaining = size
        while remaining > 0:
            chunk_size = min(remaining, MAX_PAYLOAD)
            chunk = await self._do_read(chunk_size)
            if not chunk:
                break
            parts.append(chunk)
            remaining -= len(chunk)
        return b"".join(parts)

    async def _do_read(self, size: int) -> bytes:
        request = {
            "uid": str(uuid.uuid4()),
            "fileId": self._file_id,
            "request": encode_union("FileReadRequest", {"len": size}),
        }
        response = await self._client._exchange_file(request, self._file_id)
        _, payload = decode_union(response["response"])
        err = _io_error_to_exception(payload["error"])
        data = payload.get("payload", b"")

        if isinstance(err, EOFError):
            if data:
                return data
            raise err
        if err:
            self._client._log.error(
                "fileRead failed",
                extra={"uid": request["uid"], "req": request["request"], "error": err},
            )
            raise err

        return data

    async def write(self, data: bytes) -> int:
        if not data:
            return 0

        if len(data) <= MAX_PAYLOAD:
            return await self._do_write(data)

        offset = 0
        written = 0
        while written < len(data):
            chunk = data[offset : offset + MAX_PAYLOAD]
            chunk_written = await self._do_write(chunk)
            written += chunk_written
            offset += chunk_written
        return written

    async def _do_write(self, data: bytes) -> int:
        request = {
            "uid": str(uuid.uuid4()),
            "fileId": self._file_id,
            "request": encode_union("FileWriteRequest", {"payload": data}),
        }
        response = await self._client._exchange_file(request, self._file_id)
        _, payload = decode_union(response["response"])
        err = _io_error_to_exception(payload["error"])
        if err:
            self._client._log.error(
                "fileWrite failed",
                extra={"uid": request["uid"], "req": request["request"], "error": err},
            )
            raise err
        return int(payload["len"])

    async def seek(self, offset: int, whence: int) -> int:
        request = {
            "uid": str(uuid.uuid4()),
            "fileId": self._file_id,
            "request": encode_union(
                "FileSeekRequest",
                {"offset": offset, "whence": whence},
            ),
        }
        response = await self._client._exchange_file(request, self._file_id)
        _, payload = decode_union(response["response"])
        err = _io_error_to_exception(payload["error"])
        if err:
            self._client._log.error(
                "fileSeek failed",
                extra={"uid": request["uid"], "req": request["request"], "error": err},
            )
            raise err
        return int(payload["offset"])

    async def readdir(self, count: int) -> List[FileInfo]:
        uid = str(uuid.uuid4())
        request = {
            "uid": uid,
            "fileId": self._file_id,
            "request": encode_union("ReaddirRequest", {"count": count}),
        }

        subject = FILE_PROVIDER_READDIR_TOPIC_PREFIX + uid
        sub = await self._client._nc.subscribe(subject)
        try:
            response = await self._client._exchange_file(request, self._file_id)
            _, payload = decode_union(response["response"])
            err = _io_error_to_exception(payload["error"])
            if err:
                self._client._log.error(
                    "readdir failed",
                    extra={"uid": uid, "req": request["request"], "error": err},
                )
                raise err

            if payload.get("count", 0) == 0:
                return []

            entries: List[FileInfo] = []
            while True:
                msg = await asyncio.wait_for(sub.next_msg(), timeout=DEFAULT_TIMEOUT)
                info = _decode(SCHEMAS["FileInfoResponse"], msg.data)
                entry = FileInfo(
                    name=info["name"],
                    size=info["size"],
                    mode=info["mode"],
                    mod_time=info["modTime"],
                    is_dir=info["isDir"],
                )
                entries.append(entry)

                file_path = posixpath.join(self._name, entry.name)
                self._client._cache[file_path] = entry

                if info.get("last", False):
                    break

            return entries
        finally:
            await sub.unsubscribe()

    async def stat(self) -> FileInfo:
        if (self._flag & os.O_CREAT) != 0:
            return await self._stat_via_file()
        return await self._client.stat(self._name)

    async def _stat_via_file(self) -> FileInfo:
        request = {
            "uid": str(uuid.uuid4()),
            "request": encode_union("StatRequest", {"name": self._name}),
        }
        response = await self._client._exchange(request)
        _, payload = decode_union(response["response"])
        err = _io_error_to_exception(payload["error"])
        if err:
            self._client._log.error(
                "stat failed",
                extra={"uid": request["uid"], "req": request["request"], "error": err},
            )
            raise err

        return FileInfo(
            name=payload["name"],
            size=payload["size"],
            mode=payload["mode"],
            mod_time=payload["modTime"],
            is_dir=payload["isDir"],
        )


class LazyAsyncFile:
    def __init__(self, client: FileProviderClient, name: str, flag: int, perm: int) -> None:
        self._client = client
        self._name = name
        self._flag = flag
        self._perm = perm
        self._file: Optional[AsyncFileHandle] = None

    async def close(self) -> None:
        if self._file is None:
            return
        await self._file.close()
        self._file = None

    async def read(self, size: int) -> bytes:
        await self._ensure_open()
        file = self._file
        if file is None:
            raise RuntimeError("file handle not available")
        return await file.read(size)

    async def seek(self, offset: int, whence: int) -> int:
        await self._ensure_open()
        file = self._file
        if file is None:
            raise RuntimeError("file handle not available")
        return await file.seek(offset, whence)

    async def readdir(self, count: int) -> List[FileInfo]:
        await self._ensure_open()
        file = self._file
        if file is None:
            raise RuntimeError("file handle not available")
        return await file.readdir(count)

    async def stat(self) -> FileInfo:
        if (self._flag & os.O_CREAT) != 0:
            await self._ensure_open()
            file = self._file
            if file is None:
                raise RuntimeError("file handle not available")
            return await file.stat()
        return await self._client.stat(self._name)

    async def write(self, data: bytes) -> int:
        await self._ensure_open()
        file = self._file
        if file is None:
            raise RuntimeError("file handle not available")
        return await file.write(data)

    async def _ensure_open(self) -> None:
        if self._file is None:
            self._file = await self._client._do_open_file(self._name, self._flag, self._perm)
