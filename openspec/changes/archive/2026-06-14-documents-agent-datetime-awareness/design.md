## Context

The agents service uses AgentScope 2.0.1. The documents agent is created per user session by `AgentFactory` in `agents/chat/agent_factory.py`. It currently receives a static `DOCUMENT_CHAT_PROMPT` and a toolkit that contains file access tools and `SearchKnowledgeBaseTool`, but no tool exposes the current date or time. The prompt also lacks any instruction about preferring recent documents, so the model has no signal to disambiguate stale versus current information when several matches are returned by `search_knowledge_base`.

Indexed documents already carry provenance metadata such as paths; modification time or ingestion timestamp can be obtained from the document repository or retrieval result metadata. The main gap is agent-level awareness of "now" and a prompt rule that rewards recency.

## Goals / Non-Goals

**Goals:**
- Provide the documents agent with a deterministic, read-only source of current date and time.
- Ensure the model knows the conversation start time by injecting it into the initial system prompt once per session.
- Guide the model to prefer more recent indexed documents when multiple documents could answer the user's query, and to avoid relying on outdated information.
- Keep the change localized to the agent construction, system prompt, and tool registration layers.

**Non-Goals:**
- Changing how document modification or ingestion timestamps are stored or indexed.
- Adding a new planner model or multi-agent orchestration.
- Changing the external chat API shape or SSE event format.
- Supporting user-specific timezones (use system/UTC time for now; user timezones can be added later).

## Decisions

### 1. Provide `get_current_datetime` as a `ToolBase` tool
- **Rationale:** A tool lets the model ask for the current time even mid-conversation (e.g., "what time is it now?"), while the prompt injection covers the common case without an extra tool call. The tool returns ISO-8601 formatted local time with timezone offset so the model can reason about it without conversion.
- Implement `GetCurrentDateTimeTool` in `agents/chat/tools.py`, following the existing `ToolBase` pattern (`check_permissions`, `ToolChunk` with JSON text, read-only permissions).

### 2. Inject current date and time into the system prompt only for new conversations
- **Rationale:** Repeating the current time on every turn wastes context; the model only needs a stable reference time at the start of the conversation. Because the AgentScope `Agent` is reconstructed per turn, the factory needs to know whether the session is brand-new.
- `AgentFactory.create()` accepts an optional `is_new_session` flag and an optional `system_prompt` override; the caller (`api/chat.py`) determines newness from the persisted session row and reuses a stored prompt when one exists.
- `DOCUMENT_CHAT_PROMPT` uses a template placeholder `{current_datetime}` that is replaced with an ISO-8601 string when `is_new_session` is true; when no datetime is supplied, `render_system_prompt()` omits the placeholder line.

### 3. Add recency guidance to the system prompt
- **Rationale:** Prompt-level guidance is the cheapest, least invasive way to influence retrieval ranking behavior in the short term, because existing vector search is score-only and does not rerank by recency. The instruction tells the model to prefer recent sources and, if needed, to refine queries rather than trust old chunks.
- Add text to `DOCUMENT_CHAT_PROMPT`: "When multiple indexed documents could answer the user's question, prefer information from more recent documents. Avoid relying on outdated information. If dates matter, use the current date/time provided above to judge relevance."

### 4. Update the `agentic-rag-search-assistant` spec with a recency requirement
- **Rationale:** The recency behavior is a requirement-level change to the existing agentic RAG capability. A delta spec in the change directory records that the capability now requires the agent to prefer recent documents when many documents match.
- The implementation of this requirement is primarily prompt + tool awareness, so no separate backend reranking is introduced in this change.

### 5. Store the injected system prompt on the `ChatSession` row
- **Rationale:** If a conversation is continued, the reference time should not drift to "now" on every turn; the user expects a stable reference to the conversation start. `AgentState` does not have a suitable field for extra metadata, and overwriting `state.summary` risks loss during context compression.
- Add a `system_prompt` text column to `ChatSession`. On the first turn, render the prompt with the current datetime and persist it on the session row. Subsequent turns load the stored prompt and pass it to `AgentFactory.create()`.

## Risks / Trade-offs

- [Risk] The model may still choose older documents if the prompt guidance is not strong enough or if retrieval scores dominate. → Mitigation: include explicit tool instructions and add eval tests for time-sensitive queries; consider search-time recency boosting as a follow-up.
- [Risk] Timezone handling may confuse the model if only UTC is provided. → Mitigation: include the offset (e.g., `2026-06-14T12:34:56+00:00`) and document that user-local timezones are future work.
- [Risk] Injecting a static datetime into a long-running conversation can become stale. → Mitigation: keep the `get_current_datetime` tool available for explicit time queries; the injected value represents conversation start, not wall-clock on every turn.
- [Trade-off] We are changing the system prompt content, which can affect all document-agent answers. Recency instruction is conservative and additive.
- [Trade-off] Detecting "new session" requires a flag from the chat API layer; this adds a small parameter but avoids state introspection in the factory.

## Migration Plan

1. Implement `GetCurrentDateTimeTool` and register it in `AgentFactory`.
2. Add `{current_datetime}` placeholder to `DOCUMENT_CHAT_PROMPT` and the recency instruction, via `render_system_prompt()`.
3. Update `AgentFactory.create()` to accept `is_new_session` and an optional `system_prompt`.
4. Add the `system_prompt` column to `ChatSession` and an additive migration.
5. Update `api/chat.py` to load or create the system prompt before each turn and pass it to the factory.
6. Create the `agentic-rag-search-assistant` delta spec with the recency requirement.
7. Add/update unit and integration tests.
8. Run `ruff check .` and `mypy .` in `agents/` and fix issues.
9. Apply the new migration to existing databases (the agents service applies it automatically on startup, or run it manually for test databases).
10. Rollback: revert the changed files and drop the `chat_sessions.system_prompt` column.

## Open Questions

- Should the injected datetime be local server time or UTC? (Decision: local server time with offset for readability.)
- Should recency guidance also affect `search_knowledge_base` default parameters, e.g., preferring a tighter `min_score` for time-sensitive queries? (Out of scope for this change; to be evaluated after prompt-only guidance.)
