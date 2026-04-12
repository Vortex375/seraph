import json
from collections.abc import AsyncGenerator
from typing import Any

from agentscope.message import Msg
from agentscope.pipeline import stream_printing_messages


async def stream_agent_reply(agent: Any, user_input: str) -> AsyncGenerator[str, None]:
    coroutine_task = agent(Msg("user", user_input, "user")) if callable(agent) else _noop_coroutine()
    async for event in stream_printing_messages(
        agents=[agent],
        coroutine_task=coroutine_task,
    ):
        msg = event[0]
        yield f"data: {json.dumps(msg.to_dict(), ensure_ascii=False)}\n\n"


async def _noop_coroutine() -> None:
    return None
