"""NATS connection helpers for file provider client."""

from __future__ import annotations

from os import getenv
from typing import Optional

from nats.aio.client import Client as NatsClient


def _get_nats_url() -> str:
    return getenv("NATS_URL", "nats://localhost:4222")


async def connect_nats(
    *,
    url: Optional[str] = None,
    user: Optional[str] = None,
    password: Optional[str] = None,
    token: Optional[str] = None,
    creds: Optional[str] = None,
) -> NatsClient:
    nc = NatsClient()

    await nc.connect(
        servers=[url or _get_nats_url()],
        user=user,
        password=password,
        token=token,
        user_credentials=creds,
    )
    return nc


async def connect_nats_from_env() -> NatsClient:
    return await connect_nats(
        url=_get_nats_url(),
        user=getenv("NATS_USER"),
        password=getenv("NATS_PASS"),
        token=getenv("NATS_TOKEN"),
        creds=getenv("NATS_CREDS"),
    )
