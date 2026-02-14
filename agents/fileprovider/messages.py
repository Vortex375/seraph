"""Avro schemas and helpers for file provider messages."""

from __future__ import annotations

from typing import Any, Dict, Tuple

from fastavro import parse_schema

NAMESPACE = "seraph.fileprovider"

FILE_PROVIDER_TOPIC_PREFIX = "seraph.fileprovider."
FILE_PROVIDER_FILE_TOPIC_PREFIX = "seraph.fileprovider_file."
FILE_PROVIDER_READDIR_TOPIC_PREFIX = "seraph.fileprovider_readdir."

_SCHEMA_JSON = {
    "IoError": {
        "type": "record",
        "name": "IoError",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "error", "type": "string"},
            {"name": "class", "type": "string"},
        ],
    },
    "MkdirRequest": {
        "type": "record",
        "name": "MkdirRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "name", "type": "string"},
            {"name": "perm", "type": "long"},
        ],
    },
    "MkdirResponse": {
        "type": "record",
        "name": "MkdirResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "error", "type": "IoError"},
        ],
    },
    "OpenFileRequest": {
        "type": "record",
        "name": "OpenFileRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "name", "type": "string"},
            {"name": "flag", "type": "int"},
            {"name": "perm", "type": "long"},
        ],
    },
    "OpenFileResponse": {
        "type": "record",
        "name": "OpenFileResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "fileId", "type": "string"},
            {"name": "error", "type": "IoError"},
        ],
    },
    "RemoveAllRequest": {
        "type": "record",
        "name": "RemoveAllRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "name", "type": "string"},
        ],
    },
    "RemoveAllResponse": {
        "type": "record",
        "name": "RemoveAllResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "error", "type": "IoError"},
        ],
    },
    "RenameRequest": {
        "type": "record",
        "name": "RenameRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "oldName", "type": "string"},
            {"name": "newName", "type": "string"},
        ],
    },
    "RenameResponse": {
        "type": "record",
        "name": "RenameResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "error", "type": "IoError"},
        ],
    },
    "StatRequest": {
        "type": "record",
        "name": "StatRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "name", "type": "string"},
        ],
    },
    "FileInfoResponse": {
        "type": "record",
        "name": "FileInfoResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "name", "type": "string"},
            {"name": "size", "type": "long"},
            {"name": "mode", "type": "long"},
            {"name": "modTime", "type": "long"},
            {"name": "isDir", "type": "boolean"},
            {"name": "error", "type": "IoError"},
            {"name": "last", "type": "boolean"},
        ],
    },
    "FileCloseRequest": {
        "type": "record",
        "name": "FileCloseRequest",
        "namespace": NAMESPACE,
        "fields": [],
    },
    "FileReadRequest": {
        "type": "record",
        "name": "FileReadRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "len", "type": "long"},
        ],
    },
    "FileReadResponse": {
        "type": "record",
        "name": "FileReadResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "error", "type": "IoError"},
            {"name": "payload", "type": "bytes"},
        ],
    },
    "FileWriteRequest": {
        "type": "record",
        "name": "FileWriteRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "payload", "type": "bytes"},
        ],
    },
    "FileWriteResponse": {
        "type": "record",
        "name": "FileWriteResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "error", "type": "IoError"},
            {"name": "len", "type": "int"},
        ],
    },
    "FileSeekRequest": {
        "type": "record",
        "name": "FileSeekRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "offset", "type": "long"},
            {"name": "whence", "type": "int"},
        ],
    },
    "FileSeekResponse": {
        "type": "record",
        "name": "FileSeekResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "offset", "type": "long"},
            {"name": "error", "type": "IoError"},
        ],
    },
    "FileCloseResponse": {
        "type": "record",
        "name": "FileCloseResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "error", "type": "IoError"},
        ],
    },
    "ReaddirRequest": {
        "type": "record",
        "name": "ReaddirRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "count", "type": "int"},
        ],
    },
    "ReaddirResponse": {
        "type": "record",
        "name": "ReaddirResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "count", "type": "int"},
            {"name": "error", "type": "IoError"},
        ],
    },
    "FileProviderRequest": {
        "type": "record",
        "name": "FileProviderRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "uid", "type": "string"},
            {
                "name": "request",
                "type": [
                    "MkdirRequest",
                    "OpenFileRequest",
                    "RemoveAllRequest",
                    "RenameRequest",
                    "StatRequest",
                ],
            },
        ],
    },
    "FileProviderResponse": {
        "type": "record",
        "name": "FileProviderResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "uid", "type": "string"},
            {
                "name": "response",
                "type": [
                    "MkdirResponse",
                    "OpenFileResponse",
                    "RemoveAllResponse",
                    "RenameResponse",
                    "FileInfoResponse",
                ],
            },
        ],
    },
    "FileProviderFileRequest": {
        "type": "record",
        "name": "FileProviderFileRequest",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "uid", "type": "string"},
            {"name": "fileId", "type": "string"},
            {
                "name": "request",
                "type": [
                    "FileCloseRequest",
                    "FileReadRequest",
                    "FileWriteRequest",
                    "FileSeekRequest",
                    "ReaddirRequest",
                ],
            },
        ],
    },
    "FileProviderFileResponse": {
        "type": "record",
        "name": "FileProviderFileResponse",
        "namespace": NAMESPACE,
        "fields": [
            {"name": "uid", "type": "string"},
            {
                "name": "response",
                "type": [
                    "FileCloseResponse",
                    "FileReadResponse",
                    "FileSeekResponse",
                    "FileWriteResponse",
                    "ReaddirResponse",
                ],
            },
        ],
    },
}

SCHEMAS = {name: parse_schema(schema, named_schemas=_SCHEMA_JSON) for name, schema in list(_SCHEMA_JSON.items())}


def encode_union(record_name: str, payload: Dict[str, Any]) -> Any:
    if "." in record_name:
        full_name = record_name
    else:
        full_name = f"{NAMESPACE}.{record_name}"
    return (full_name, payload)


def decode_union(value: Any) -> Tuple[str, Any]:
    if isinstance(value, dict) and len(value) == 1:
        name, payload = next(iter(value.items()))
        return name, payload
    if isinstance(value, dict):
        return "", value
    raise ValueError("Invalid union value")
