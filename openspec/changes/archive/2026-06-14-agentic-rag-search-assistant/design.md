## Context

The agents chat service is built on **AgentScope 1.0.18**. It constructs a `ReActAgent` on every turn, injects a `SeraphKnowledgeBase` into the agent's `knowledge` slot, and pre-loads the model with retrieved chunks via `_retrieve_turn_sources()` in `api/chat.py`. The streaming layer uses the v1 `stream_printing_messages` helper, and conversation history is persisted through `AsyncSQLAlchemyMemory`.

AgentScope 2.0.1 is a breaking release:

- `ReActAgent` is replaced by the unified `Agent` class.
- `Agent.__call__` is replaced by `reply_stream()` / `reply()`.
- Tools must satisfy the `ToolBase` interface (with `check_permissions`) and be passed as objects to `Toolkit(...)`.
- `OpenAIChatModel` now takes a `Credential` object; formatters move to the model.
- The `agentscope.memory` module is removed and v1 memory classes (`AsyncSQLAlchemyMemory`) no longer exist.
- The `agentscope.rag` module is removed, so `KnowledgeBase` and `KnowledgeBase`-backed retrieval are gone.
- Streaming is event-based (`TextBlockDeltaEvent`, `ToolResultEndEvent`, `ReplyEndEvent`, etc.).

Because the agentic-RAG change touches exactly the APIs that break in 2.0, we should first upgrade AgentScope and then implement the new search tool on the v2 API surface.

The rest of the stack — PostgreSQL with `pgvector`, `retrieval/service.py`, the OpenAI embedder, and the NATS-based spaces client — stays the same.

## Goals / Non-Goals

**Goals:**
- Upgrade the agents service to AgentScope 2.0.1 and make the existing chat endpoints work on the new API.
- Replace fixed RAG with agentic RAG: the model decides when to call a `search_knowledge_base` tool.
- Allow the assistant to answer greetings and out-of-scope queries without retrieving or citing documents.
- Enable iterative, multi-step semantic search within a single turn.
- Preserve citation provenance for documents the agent actually uses.

**Non-Goals:**
- Rewriting the embedding model, storage layer, or spaces authorization.
- Adding a planner model or multi-agent orchestration.
- Changing the external chat API contract (same SSE events and messages list shape).
- Migrating to the new AgentScope `Agent Service`, `Workspace`, or multi-tenant abstractions.

## Decisions

### 1. Upgrade to AgentScope 2.0.1 first, then build agentic RAG
- **Rationale:** The RAG work intersects the exact classes that 2.0 removes (`ReActAgent`, `Toolkit.register_tool_function`, `AsyncSQLAlchemyMemory`, `KnowledgeBase`). Upgrading first avoids implementing on a dead API and then porting.
- Pin `agentscope==2.0.1` in `pyproject.toml` and `requirements.txt`, regenerate `uv.lock`, reinstall, and fix compile/import errors before adding the new tool.

### 2. Replace `ReActAgent` with the new `Agent`
- Construct `Agent(name="seraph-documents", system_prompt=DOCUMENT_CHAT_PROMPT, model=..., toolkit=..., state=...)`.
- Use `agent.reply_stream(UserMsg(name="user", content=message))` instead of the old `__call__` + `stream_printing_messages`.

### 3. Adapt the chat model construction
- Use `OpenAICredential(api_key=..., base_url=...)` and pass it to `OpenAIChatModel(credential=..., model=..., stream=True)`.
- Drop `DeepSeekChatFormatter` / `client_kwargs`; the OpenAI-compatible endpoint works with the default formatter. If DeepSeek-specific formatting is needed, configure the model's `formatter` argument in v2.
- Update `RuntimeSessionTitleSummarizer` in `app/main.py` to the same credential/model pattern.

### 4. Replace `AsyncSQLAlchemyMemory` with persisted `AgentState`
- Add an `agent_state: Mapped[dict] = mapped_column(JSON, default=dict)` column to `ChatSession`.
- Implement a small `chat/agent_state_store.py` that loads/saves `AgentState` (Pydantic model) as JSON for a `(user_id, session_id)` pair.
- On `AgentFactory.create()`, load the latest state (or create a fresh `AgentState(session_id=...)`); after each reply, persist the updated state.
- This replaces `_persist_user_message()` and the v1 memory table. The `list_messages` implementation can derive visible messages from the persisted `AgentState` JSON instead of the removed memory table.
- Remove the `initialize_database_schema()` call that creates `agentscope.memory._working_memory._sqlalchemy_memory` tables.

### 5. Convert file-access helpers into `ToolBase` tools
- v2 `Toolkit` accepts `ToolBase` instances, not `register_tool_function` closures.
- Create one lightweight `ToolBase` subclass per operation (`search_files`, `list_directory`, `stat_file`, `read_file_excerpt`).
- Each tool:
  - marks `is_read_only = True`,
  - returns `PermissionDecision(behavior=PermissionBehavior.ALLOW)` from `check_permissions()`,
  - gets the per-user `AgentFileAccessService` injected at construction,
  - returns a `ToolChunk(content=[TextBlock(text=json.dumps(payload))], metadata={"citations": [...] | []})`.
- Tool output is JSON so the model receives structured results; the citation metadata is used by the chat layer, not exposed to the LLM.

### 6. Implement `search_knowledge_base` as a `ToolBase` tool
- The tool receives `query`, optional `limit` (default 5), and optional `min_score` (default 0.0).
- It resolves user scopes via the spaces client, embeds the query, calls `RetrievalService.retrieve()`, formats a readable summary, and stores citation provenance in the `ToolChunk.metadata["citations"]` list.
- Since v2 removed `agentscope.rag.KnowledgeBase`, `SeraphKnowledgeBase` is no longer a framework knowledge base. It becomes a plain Python search adapter (or is replaced by a direct call to `RetrievalService` + scope resolution). If kept, it only supplies `retrieve()`; it is not passed to `Agent(...)` as `knowledge`.

### 7. Remove eager retrieval from `_stream_chat_events()`
- Delete `_retrieve_turn_sources()` and its call site so the agent is not pre-fed chunks.
- Citation assembly now relies exclusively on tool-result metadata collected during the event stream.

### 8. Refactor streaming to consume v2 events
- Replace `stream_printing_messages` with a loop over `AgentEvent` objects.
- Relevant event types:
  - `ReplyStartEvent` → assistant message id = `event.reply_id`.
  - `TextBlockDeltaEvent` → yield an SSE delta chunk.
  - `ToolResultEndEvent` → if successful, extract `metadata["citations"]` and append to the turn citation list.
  - `ReplyEndEvent` → finalize the reply.
- Keep the same SSE payload shape (`{id, role, type, content, citations}`) so the existing UI does not change.

### 9. Update `DOCUMENT_CHAT_PROMPT`
- Replace "Use retrieved document context first" with instructions to use the `search_knowledge_base` tool only when the answer depends on indexed documents.
- Tell the agent it may answer greetings and simple questions directly.
- Keep the citation requirement for any concrete file reference.

### 10. Default search limits
- Keep default `limit=5` to match current top-k behavior; allow `limit` up to ~20 and optional `min_score` filtering.

## Risks / Trade-offs

- [Risk] AgentScope 2.0.1 removes the memory module, so existing conversation persistence might require schema and history-listing changes. → Mitigation: persist `AgentState` JSON in the existing `chat_sessions` table and derive list-messages from it.
- [Risk] Tool/citation capture semantics change; tests that stubbed `Toolkit.register_tool_function` need rewriting. → Mitigation: add v2-aware unit tests before production verification.
- [Risk] The model may under-retrieve on complex questions. → Mitigation: prompt engineering and eval scenarios for queries requiring lookup.
- [Risk] Unconditional top-k retrieval was deterministic; answer quality now depends on the model.
- [Trade-off] Agent state is serialized to JSON; very long conversations may produce large blobs. The built-in v2 context compression should keep them bounded without extra code in this change.

## Migration Plan

1. Update dependency files to `agentscope==2.0.1` and regenerate the lockfile.
2. Fix import-level breakage (`ReActAgent`, `AsyncSQLAlchemyMemory`, `KnowledgeBase`, `register_tool_function`, `stream_printing_messages`, `DeepSeekChatFormatter`, model constructors).
3. Add `agent_state` JSON column to `ChatSession` and implement the state store.
4. Migrate `agent_factory.py` to v2 `Agent`, `OpenAICredential`, and `ToolBase` tools (including the new `search_knowledge_base`).
5. Migrate `api/chat.py` to event-based streaming and remove `_retrieve_turn_sources()`.
6. Update `chat/session_service.py` to derive messages from persisted `AgentState` or keep current citation tables.
7. Update `chat/prompts.py`.
8. Update `app/main.py` model creation and schema initialization.
9. Update/rewrite tests for the new API surface and add agentic-RAG cases.
10. Run `ruff` and `mypy` in the `agents/` directory.
11. Rollback: restore `agentscope==1.0.18` and revert the migrated files.

## Open Questions

- Should we keep a fallback auto-retrieval path for questions the model answers without tools? (Out of scope; monitor first.)
- Should we expose path-prefix filtering in `search_knowledge_base` so multi-step research can narrow by provider/folder? (Consider as follow-up.)
