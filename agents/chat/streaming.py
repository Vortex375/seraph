import json
from collections.abc import AsyncGenerator
from typing import Any

from agentscope.event import (
    ReplyEndEvent,
    ReplyStartEvent,
    TextBlockDeltaEvent,
    ToolResultEndEvent,
)
from agentscope.message import ToolResultState, UserMsg


async def stream_agent_reply(agent: Any, user_input: str) -> AsyncGenerator[str, None]:
    reply_id: str | None = None
    user_msg = UserMsg(name="user", content=user_input)
    try:
        setattr(agent, "_seraph_tool_citations", [])
    except Exception:
        pass
    async for event in agent.reply_stream(user_msg):
        if isinstance(event, ReplyStartEvent):
            reply_id = event.reply_id
        elif isinstance(event, TextBlockDeltaEvent):
            payload = {
                "id": reply_id,
                "role": "assistant",
                "type": "delta",
                "content": event.delta,
            }
            yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"
        elif isinstance(event, ToolResultEndEvent):
            if event.state == ToolResultState.SUCCESS:
                try:
                    citations = _collect_tool_citations(agent)
                    setattr(agent, "_seraph_tool_citations", citations)
                except Exception:
                    pass
        elif isinstance(event, ReplyEndEvent):
            payload = {"id": reply_id, "role": "assistant", "type": "done"}
            yield f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


def _collect_tool_citations(agent: Any) -> list[dict[str, str]]:
    citations: list[dict[str, str]] = []
    seen: set[tuple[str, str]] = set()
    toolkit = getattr(agent, "toolkit", None)
    if toolkit is None:
        return citations
    for group in getattr(toolkit, "tool_groups", []):
        for tool in getattr(group, "tools", []):
            tool_citations = getattr(tool, "_citations", None)
            if not isinstance(tool_citations, list):
                continue
            for citation in tool_citations:
                if not isinstance(citation, dict):
                    continue
                provider_id = citation.get("provider_id")
                path = citation.get("path")
                if not isinstance(provider_id, str) or not provider_id:
                    continue
                if not isinstance(path, str) or not path:
                    continue
                key = (provider_id, path)
                if key in seen:
                    continue
                seen.add(key)
                citations.append(citation)
    return citations
