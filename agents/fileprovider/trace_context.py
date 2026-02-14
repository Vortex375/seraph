"""TraceContext propagation helpers for NATS headers."""

from __future__ import annotations

from typing import Dict

from opentelemetry.propagate import inject


def inject_trace_context(headers: Dict[str, str] | None = None) -> Dict[str, str]:
    carrier: Dict[str, str] = headers or {}
    inject(carrier)
    return carrier
