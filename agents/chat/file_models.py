from __future__ import annotations

from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class FileCitation:
    provider_id: str
    path: str
    label: str

    def to_dict(self) -> dict[str, str]:
        return asdict(self)


@dataclass(frozen=True)
class FileEntry:
    provider_id: str
    path: str
    name: str
    size: int
    mod_time: int
    is_dir: bool

    def to_dict(self) -> dict[str, str | int | bool]:
        return asdict(self)


@dataclass(frozen=True)
class FileReadExcerpt:
    reference: FileCitation
    content: str | None
    message: str | None
    start_line: int
    end_line: int | None
    truncated: bool

    def to_dict(self) -> dict[str, object]:
        return {
            "reference": self.reference.to_dict(),
            "content": self.content,
            "message": self.message,
            "start_line": self.start_line,
            "end_line": self.end_line,
            "truncated": self.truncated,
        }
