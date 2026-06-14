## 1. Implement the current date/time tool

- [x] 1.1 Add `GetCurrentDateTimeTool` class to `agents/chat/tools.py`, returning ISO-8601 local time with timezone offset and an empty citations list.
- [x] 1.2 Register `GetCurrentDateTimeTool` in `AgentFactory._build_tools()` in `agents/chat/agent_factory.py`.
- [x] 1.3 Add a helper to format the current datetime consistently for both the tool and the prompt injection.

## 2. Update the documents agent system prompt

- [x] 2.1 Convert `DOCUMENT_CHAT_PROMPT` in `agents/chat/prompts.py` to a template that can replace a `{current_datetime}` placeholder.
- [x] 2.2 Add recency guidance text to the prompt instructing the model to prefer recent documents and avoid outdated information when many documents match.
- [x] 2.3 Keep the prompt semantically equivalent when no datetime injection is requested.

## 3. Inject current datetime once per new conversation

- [x] 3.1 Add an `is_new_session` parameter to `AgentFactory.create()` and conditionally render the system prompt with the current datetime.
- [x] 3.2 Persist the rendered system prompt in `ChatSession.system_prompt` (with a migration) so subsequent turns reuse the same value.
- [x] 3.3 Update the chat streaming / API layer (`agents/api/chat.py`) to compute and reuse the system prompt when a new `ChatSession` is created.
- [x] 3.4 Ensure `RuntimeAgentFactory.create()` forwards keyword arguments to `AgentFactory.create()` so callers can pass `is_new_session` and `system_prompt`.

## 4. Update the agentic RAG specification with the recency requirement

- [x] 4.1 Add the new recency requirement to `openspec/specs/agentic-rag-search-assistant/spec.md` under the existing requirements.
- [x] 4.2 Verify the archived delta spec in `openspec/changes/documents-agent-datetime-awareness/specs/agentic-rag-search-assistant/spec.md` matches the final requirement text.

## 5. Add tests and verification

- [x] 5.1 Update `agents/tests/test_agent_factory.py` to assert that `GetCurrentDateTimeTool` is registered and that its `check_permissions` allows read-only access.
- [x] 5.2 Add a test verifying the rendered system prompt contains the injected datetime when `is_new_session=True` and omits it otherwise.
- [x] 5.3 Add a test verifying the system prompt contains the recency guidance text.
- [x] 5.4 Update `agents/tests/test_chat_streaming.py` to assert the rendered system prompt is persisted on `ChatSession.system_prompt` and reused across turns.
- [x] 5.5 Run `uv run ruff check .` and `uv run mypy .` in the `agents/` directory and fix reported issues.
- [x] 5.6 Run the agents test suite (unit tests first, then integration tests if services are available) and fix regressions.
