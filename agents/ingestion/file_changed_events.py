"""Avro schema decoding for FileChangedEvent messages."""

from __future__ import annotations

from dataclasses import dataclass
from io import BytesIO
from typing import Any, Dict, cast

from fastavro import parse_schema, schemaless_reader

EVENT_SCHEMA: Dict[str, Any] = {
    "type": "record",
    "name": "Event",
    "namespace": "seraph.events",
    "fields": [
        {"name": "id", "type": "string"},
        {"name": "version", "type": "int"},
    ],
}

FILE_CHANGED_SCHEMA: Dict[str, Any] = {
    "type": "record",
    "name": "FileChangedEvent",
    "namespace": "seraph.events",
    "fields": [
        {"name": "event", "type": "Event"},
        {"name": "fileId", "type": "string"},
        {"name": "providerId", "type": "string"},
        {"name": "change", "type": "string"},
        {"name": "path", "type": "string"},
        {"name": "size", "type": "long"},
        {"name": "mode", "type": "long"},
        {"name": "modTime", "type": "long"},
        {"name": "isDir", "type": "boolean"},
        {"name": "mime", "type": "string"},
    ],
}

_NAMED_SCHEMAS: Dict[str, Any] = {"seraph.events.Event": EVENT_SCHEMA}
_PARSED_FILE_CHANGED_SCHEMA = parse_schema(FILE_CHANGED_SCHEMA, named_schemas=_NAMED_SCHEMAS)


@dataclass(frozen=True)
class FileChangedEvent:
    event_id: str
    event_version: int
    file_id: str
    provider_id: str
    change: str
    path: str
    size: int
    mode: int
    mod_time: int
    is_dir: bool
    mime: str


def decode_file_changed_event(payload: bytes) -> FileChangedEvent:
    buffer = BytesIO(payload)
    data = cast(Dict[str, Any], schemaless_reader(buffer, _PARSED_FILE_CHANGED_SCHEMA, None))
    event = cast(Dict[str, Any], data.get("event") or {})

    return FileChangedEvent(
        event_id=event.get("id", ""),
        event_version=event.get("version", 0),
        file_id=data.get("fileId", ""),
        provider_id=data.get("providerId", ""),
        change=data.get("change", ""),
        path=data.get("path", ""),
        size=int(data.get("size", 0) or 0),
        mode=int(data.get("mode", 0) or 0),
        mod_time=int(data.get("modTime", 0) or 0),
        is_dir=bool(data.get("isDir", False)),
        mime=data.get("mime", "") or "",
    )
