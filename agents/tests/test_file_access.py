import sys
from pathlib import Path

import pytest

sys.path.append(str(Path(__file__).resolve().parents[1]))

from chat.file_access import AgentFileAccessService
from spaces.access import SpaceScope


@pytest.mark.asyncio
async def test_list_directory_rejects_path_outside_scope() -> None:
    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            assert user_id == "alice"
            return [SpaceScope(provider_id="space-a", path_prefix="/team")]

    service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: None,
        search_client=None,
    )

    with pytest.raises(PermissionError):
        await service.list_directory(user_id="alice", provider_id="space-a", path="/private")


@pytest.mark.asyncio
async def test_root_scoped_provider_allows_nested_paths() -> None:
    class StubFileProvider:
        async def stat(self, path: str):
            assert path == "/team/spec.txt"
            return type("Info", (), {"name": "spec.txt", "size": 12, "mod_time": 1, "is_dir": False})()

    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            del user_id
            return [SpaceScope(provider_id="space-a", path_prefix="/")]

    service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(),
        search_client=None,
    )

    result = await service.stat_file(user_id="alice", provider_id="space-a", path="/team/spec.txt")

    assert result["path"] == "/team/spec.txt"


@pytest.mark.asyncio
async def test_stat_and_list_directory_return_normalized_metadata() -> None:
    class StubDirHandle:
        async def readdir(self, count: int):
            del count
            return [
                type("Info", (), {"name": "spec.md", "size": 12, "mod_time": 123, "is_dir": False})(),
                type("Info", (), {"name": "notes", "size": 0, "mod_time": 456, "is_dir": True})(),
            ]

        async def close(self) -> None:
            return None

    class StubFileProvider:
        async def stat(self, path: str):
            assert path == "/team"
            return type("Info", (), {"name": "team", "size": 0, "mod_time": 999, "is_dir": True})()

        async def open_file(self, path: str, flag: int, perm: int):
            del flag, perm
            assert path == "/team"
            return StubDirHandle()

    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            del user_id
            return [SpaceScope(provider_id="space-a", path_prefix="/team")]

    service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(),
        search_client=None,
    )

    stat_result = await service.stat_file(user_id="alice", provider_id="space-a", path="/team")
    list_result = await service.list_directory(user_id="alice", provider_id="space-a", path="/team")

    assert stat_result["path"] == "/team"
    assert stat_result["is_dir"] is True
    assert [entry["path"] for entry in list_result] == ["/team/spec.md", "/team/notes"]


@pytest.mark.asyncio
async def test_read_file_excerpt_returns_requested_line_window() -> None:
    class StubFile:
        async def read(self, size: int) -> bytes:
            assert size == 128
            return b"line1\nline2\nline3\nline4\n"

        async def close(self) -> None:
            return None

    class StubFileProvider:
        async def stat(self, path: str):
            assert path == "/team/spec.txt"
            return type("Info", (), {"name": "spec.txt", "size": 24, "mod_time": 1, "is_dir": False})()

        async def open_file(self, path: str, flag: int, perm: int):
            del path, flag, perm
            return StubFile()

    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            del user_id
            return [SpaceScope(provider_id="space-a", path_prefix="/team")]

    service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(),
        search_client=None,
        max_read_bytes=128,
        max_inline_file_size=128,
    )

    result = await service.read_file_excerpt(
        user_id="alice",
        provider_id="space-a",
        path="/team/spec.txt",
        start_line=2,
        max_lines=2,
        max_chars=20,
    )

    assert result["content"] == "line2\nline3"
    assert result["start_line"] == 2
    assert result["end_line"] == 3
    assert result["truncated"] is False


@pytest.mark.asyncio
async def test_read_file_excerpt_can_seek_to_later_lines_within_inline_limit() -> None:
    line_map = {
        0: b"line1\nline2\nline3\n",
        18: b"line4\nline5\nline6\n",
    }

    class StubFile:
        def __init__(self) -> None:
            self.offset = 0

        async def seek(self, offset: int, whence: int) -> int:
            assert whence == 0
            self.offset = offset
            return self.offset

        async def read(self, size: int) -> bytes:
            assert size == 18
            return line_map.get(self.offset, b"")

        async def close(self) -> None:
            return None

    class StubFileProvider:
        async def stat(self, path: str):
            assert path == "/team/spec.txt"
            return type("Info", (), {"name": "spec.txt", "size": 36, "mod_time": 1, "is_dir": False})()

        async def open_file(self, path: str, flag: int, perm: int):
            del path, flag, perm
            return StubFile()

    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            del user_id
            return [SpaceScope(provider_id="space-a", path_prefix="/team")]

    service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(),
        search_client=None,
        max_read_bytes=18,
        max_inline_file_size=128,
    )

    result = await service.read_file_excerpt(
        user_id="alice",
        provider_id="space-a",
        path="/team/spec.txt",
        start_line=4,
        max_lines=2,
        max_chars=20,
    )

    assert result["content"] == "line4\nline5"
    assert result["start_line"] == 4
    assert result["end_line"] == 5
    assert result["truncated"] is False


@pytest.mark.asyncio
async def test_read_file_excerpt_rejects_binary_or_large_files() -> None:
    class StubFile:
        async def read(self, size: int) -> bytes:
            assert size == 32
            return b"hello from seraph"

        async def close(self) -> None:
            return None

    class StubBinaryFile(StubFile):
        async def read(self, size: int) -> bytes:
            del size
            return b"\xff\xfe\x00\x01"

    class StubFileProvider:
        def __init__(self, size: int, reader_cls: type[StubFile]):
            self._size = size
            self._reader_cls = reader_cls

        async def stat(self, path: str):
            del path
            return type("Info", (), {"name": "spec.txt", "size": self._size, "mod_time": 1, "is_dir": False})()

        async def open_file(self, path: str, flag: int, perm: int):
            del path, flag, perm
            return self._reader_cls()

    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            del user_id
            return [SpaceScope(provider_id="space-a", path_prefix="/team")]

    binary_service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(12, StubBinaryFile),
        search_client=None,
        max_read_bytes=32,
        max_inline_file_size=128,
    )
    binary_result = await binary_service.read_file_excerpt(
        user_id="alice", provider_id="space-a", path="/team/spec.bin"
    )
    assert binary_result["content"] is None
    assert "can't read" in binary_result["message"]

    large_service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(1024, StubFile),
        search_client=None,
        max_read_bytes=32,
        max_inline_file_size=128,
    )
    large_result = await large_service.read_file_excerpt(
        user_id="alice", provider_id="space-a", path="/team/spec.txt"
    )
    assert large_result["content"] is None
    assert "too large" in large_result["message"]


@pytest.mark.asyncio
async def test_read_file_excerpt_treats_eof_as_normal_completion() -> None:
    class StubFile:
        def __init__(self) -> None:
            self.calls = 0

        async def read(self, size: int) -> bytes:
            assert size == 8
            self.calls += 1
            if self.calls == 1:
                return b"line1\n"
            raise EOFError("eof")

        async def close(self) -> None:
            return None

    class StubFileProvider:
        async def stat(self, path: str):
            del path
            return type("Info", (), {"name": "spec.txt", "size": 6, "mod_time": 1, "is_dir": False})()

        async def open_file(self, path: str, flag: int, perm: int):
            del path, flag, perm
            return StubFile()

    class StubSpacesClient:
        async def get_scopes_for_user(self, user_id: str):
            del user_id
            return [SpaceScope(provider_id="space-a", path_prefix="/team")]

    service = AgentFileAccessService(
        spaces_client=StubSpacesClient(),
        file_provider_factory=lambda provider_id: StubFileProvider(),
        search_client=None,
        max_read_bytes=8,
        max_inline_file_size=128,
    )

    result = await service.read_file_excerpt(
        user_id="alice",
        provider_id="space-a",
        path="/team/spec.txt",
        start_line=1,
        max_lines=2,
        max_chars=20,
    )

    assert result["content"] == "line1"
    assert result["truncated"] is False
