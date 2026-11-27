import json
from collections.abc import AsyncGenerator
from typing import Any
from uuid import uuid4

from pydantic_ai import AgentRunResultEvent, PartDeltaEvent, PartStartEvent, TextPart, TextPartDelta


def _sse(payload: dict[str, Any]) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


async def stream_agent_reply(agent: Any, user_input: str) -> AsyncGenerator[str, None]:
    """Run one turn of a ``ChatAgent`` and yield its text as SSE delta payloads.

    The reply id doubles as the Pydantic AI ``run_id``, so persisted history can be joined to turn state.
    """
    reply_id = str(uuid4())
    async with agent.agent.run_stream_events(
        user_input, message_history=agent.state, deps=agent.deps, run_id=reply_id
    ) as events:
        async for event in events:
            delta = None
            if isinstance(event, PartStartEvent) and isinstance(event.part, TextPart):
                delta = event.part.content
            elif isinstance(event, PartDeltaEvent) and isinstance(event.delta, TextPartDelta):
                delta = event.delta.content_delta
            elif isinstance(event, AgentRunResultEvent):
                agent.state = event.result.all_messages()
                yield _sse({"id": reply_id, "role": "assistant", "type": "done"})
            if delta:
                yield _sse({"id": reply_id, "role": "assistant", "type": "delta", "content": delta})
