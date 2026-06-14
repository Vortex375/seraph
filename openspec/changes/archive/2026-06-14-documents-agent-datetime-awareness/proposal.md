## Why

The documents agent currently has no access to the current date and time, so it cannot reason about document recency, answer time-sensitive user questions, or prefer recent information when many indexed documents match a query. Giving the agent explicit datetime awareness—both through a tool and a one-time prompt injection—improves answer relevance and reduces stale answers.

## What Changes

- Add a new read-only tool `get_current_datetime` to the documents agent that returns the current system date and time (with timezone offset).
- Inject the current date and time into the agent's system prompt once when a new conversation is created, so the model knows the reference time without calling a tool for basic time context.
- Update the document assistant's system prompt to instruct the model to prefer recent documents and to avoid relying on outdated information when multiple indexed documents could answer the user's question.
- Update the existing retrieval/search behavior guidance in the `agentic-rag-search-assistant` capability to require recency-preference semantics.
- Add unit and integration tests for the new tool, prompt injection, and recency prompt guidance.

## Capabilities

### New Capabilities

- `documents-agent-datetime-awareness`: Documents agent can query the current date/time and receives a one-time datetime injection in its system prompt for a new conversation.

### Modified Capabilities

- `agentic-rag-search-assistant`: Add a requirement that when many documents match a user query, the agent SHALL prefer more recent documents and avoid relying on outdated information.

## Impact

- `agents/chat/tools.py`: implement `GetCurrentDateTimeTool`.
- `agents/chat/prompts.py`: extend `DOCUMENT_CHAT_PROMPT` with the recency instruction and a placeholder for the injected current date/time.
- `agents/chat/agent_factory.py`: register the new tool and render the system prompt with the current datetime on first agent creation for a new session.
- `agents/chat/session_service.py`: detect new conversations so the datetime is injected only once per session.
- `agents/tests/test_agent_factory.py` and `agents/tests/test_chat_streaming.py`: add coverage for tool registration and prompt content.
- `openspec/specs/agentic-rag-search-assistant/spec.md`: add the recency requirement.
