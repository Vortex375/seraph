import json
import os
import secrets
import selectors
import subprocess
import time
from pathlib import Path
from typing import AsyncGenerator, Dict

import pytest
import pytest_asyncio

from fileprovider.client import FileProviderClient
from fileprovider.nats_client import connect_nats


def _read_line_with_timeout(proc: subprocess.Popen, timeout: float) -> str:
    if proc.stdout is None:
        raise RuntimeError("missing stdout for testserver")

    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        remaining = max(deadline - time.monotonic(), 0.0)
        events = selector.select(timeout=remaining)
        if not events:
            continue
        line = proc.stdout.readline()
        if line:
            return line.strip()
        break

    stderr = ""
    if proc.stderr is not None:
        stderr = proc.stderr.read()
    raise RuntimeError(f"testserver did not start: {stderr}")


@pytest_asyncio.fixture
async def testserver_info() -> AsyncGenerator[Dict[str, str], None]:
    repo_root = Path(__file__).resolve().parents[2]
    server_dir = repo_root / "file-provider"

    proc = subprocess.Popen(
        ["go", "run", "./cmd/fileprovider-testserver"],
        cwd=server_dir,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    try:
        line = _read_line_with_timeout(proc, timeout=15.0)
        info = json.loads(line)
        yield info
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=10.0)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5.0)


@pytest_asyncio.fixture
async def fileprovider_client(testserver_info: Dict[str, str]) -> AsyncGenerator[FileProviderClient, None]:
    nc = await connect_nats(url=testserver_info["nats_url"])
    client = FileProviderClient(testserver_info["provider_id"], nc)
    try:
        yield client
    finally:
        await nc.close()


@pytest.mark.asyncio
async def test_large_payload_roundtrip(fileprovider_client: FileProviderClient):
    payload = secrets.token_bytes(2048 * 1024)

    file = await fileprovider_client.open_file(
        "testfile",
        os.O_CREAT | os.O_TRUNC | os.O_WRONLY,
        0o644,
    )
    written = await file.write(payload)
    assert written == len(payload)
    await file.close()

    file = await fileprovider_client.open_file("testfile", os.O_RDONLY, 0)
    data = await file.read(len(payload))
    assert data == payload

    with pytest.raises(EOFError):
        await file.read(1)

    await file.close()


@pytest.mark.asyncio
async def test_basic_operations(fileprovider_client: FileProviderClient):
    await fileprovider_client.mkdir("dir1", 0o755)

    info = await fileprovider_client.stat("dir1")
    assert info.is_dir is True

    await fileprovider_client.rename("dir1", "dir2")

    info = await fileprovider_client.stat("dir2")
    assert info.is_dir is True

    await fileprovider_client.remove_all("dir2")


@pytest.mark.asyncio
async def test_readdir(fileprovider_client: FileProviderClient):
    await fileprovider_client.mkdir("dir3", 0o755)

    for name in ["file1", "file2", "file3"]:
        file = await fileprovider_client.open_file(
            f"dir3/{name}",
            os.O_CREAT | os.O_TRUNC | os.O_WRONLY,
            0o644,
        )
        await file.write(b"data")
        await file.close()

    dir_handle = await fileprovider_client.open_file("dir3", os.O_RDONLY, 0)
    entries = await dir_handle.readdir(0)
    await dir_handle.close()

    names = {entry.name for entry in entries}
    assert names == {"file1", "file2", "file3"}
